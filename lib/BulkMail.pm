package BulkMail;

use Dancer ':syntax';
use Dancer::Plugin::Database;
use HTML::Entities;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Simple::Creator;
use Email::Sender::Transport::Mbox;
use Email::Sender::Transport::SMTP;
use IO::Socket::SSL;
use DBI;

our $VERSION = '0.1';

sub connect_db {
  my $db = DBI->connect("dbi:SQLite:dbname=".config->{sqlite}{db}) or
     die $DBI::errstr;

  return $db;
}

sub init_db {
    my $db = connect_db();

    # slurp sql schema
    my $schema = do { local(@ARGV,$/) = config->{sqlite}{schema}; <>};
    $db->do($schema) or die $db->errstr;
    return $db;
}

sub flatten {
  map { ref $_ ? flatten(@{$_}) : $_ } @_;
}

get '/mailing/:key' => sub {

    my $db = connect_db();
    my $stm = $db->prepare("select * from mbox where key = ?");
    $stm->execute(param('key'));
    if (my $row = $stm->fetchrow_hashref()) {

        my @froms;
        for my $from (@{config->{froms}}) {
            push @froms, encode_entities($from);
        }
        session key => param('key');
        session row => $row;
        template 'mailing', {subject => encode_entities($row->{subject}),
                             from => encode_entities($row->{from_address}),
                             date => encode_entities($row->{date}),
                             body => encode_entities($row->{body}),
                             froms => \@froms};
    } else {
        template 'index', { error => "Key niet gevonden" };
    }
};

get '/submitted/:ackkey' => sub {

    my $db = connect_db();
    my $stm = $db->prepare("select * from mbox where ackkey = ?");
    $stm->execute(param('ackkey'));
    if (my $row = $stm->fetchrow_hashref()) {

        session ackkey => param('ackkey');
        session row => $row;
        template 'submitted', {subject => encode_entities($row->{subject}),
                             from => encode_entities($row->{new_from_address}),
                             date => encode_entities($row->{date}),
                             body => encode_entities($row->{body})};

    } else {
        template 'index', { error => "Key niet gevonden" };
    }
};

post '/recipients' => sub {

    if (defined params->{afz}) {

        # update sqlite database
        my $db = connect_db();
        my $stm = $db->prepare( config->{sqlite}{update_from} );
        unless ($stm->execute(param('afz'),session('key'))) {
            template 'index', { error => "Fout in update afzender adres" };
            return;
        }
        session->{row}{new_from_address} = param('afz');
        my $row = session('row');
        my $st1 = database->prepare( config->{queries}{prov} );
        my $st2 = database->prepare( config->{queries}{city} );

        $st1->execute();
        $st2->execute();

        my @prov = flatten( @{ $st1->fetchall_arrayref() } );
        my @city = flatten( @{ $st2->fetchall_arrayref() } );
        my @list = sort keys %{ config->{list} };

        template 'recipients', {subject => encode_entities($row->{subject}),
                                date => encode_entities($row->{date}),
                                new_from => encode_entities($row->{new_from_address}),
                                prov => \@prov, city => \@city, list => \@list};
    } else {
        template 'index', { error => "Fout in nieuw afzender adres" };
    }
};

post '/submit' => sub {

    if (defined session('row')) {

        my $row = session('row');
        my $db = connect_db();
        my $stm = $db->prepare( config->{sqlite}{update_rcpt} );

        if (defined params->{provSubmit} and defined params->{provarea}) {

            session selfrom => "provincie";
            session recipients => params->{provarea};
            $stm->execute("provincie", params->{provarea}, $row->{key});

        } elsif (defined params->{citySubmit} and defined params->{cityarea}) {

            session selfrom => "gemeente";
            session recipients => params->{cityarea};
            $stm->execute("gemeente", params->{cityarea}, $row->{key});

        } elsif (defined params->{listSubmit} and defined params->{listarea}) {

            session selfrom => "lists";
            session recipients => params->{listarea};
            $stm->execute("lists", params->{listarea}, $row->{key});
        }

        if (defined session->{selfrom} and defined session->{recipients} ) {

            sendNotify();
            template 'submit', {subject => encode_entities($row->{subject}),
                                date => encode_entities($row->{date}),
                                new_from => encode_entities($row->{new_from_address}),
                                selfrom => session->{selfrom},
                                authorize_by => encode_entities( config->{authorize_by} ),
                                recipients => encode_entities( session->{recipients} )}

        } else {
            template 'index', { error => "Error in submitted form" };
        }

    } else {
        template 'index', { error => "Session key not found" };
    }
};

any qr{.*} => sub {
    status 'not_found';
    template 'index', { error => "404 Not Found" };
};

sub sendReceipt {

    my ($email,$key) = @_;

    my $transport = Email::Sender::Transport::SMTP->new({
        host => config->{smtp}{host},
        ssl => config->{smtp}{ssl},
        SSL_verify_mode => SSL_VERIFY_NONE,
        sasl_username => config->{smtp}{user},
        sasl_password => config->{smtp}{pass},
        debug => 1,
    });
    my $reply = Email::Simple->create(
        header => [
            To      => $email->header("From"),
            From    => $email->header("To"),
            Subject => "Ontvangen: " . $email->header("Subject"),
        ],
        body => template 'sendrcpt', { myurl => config->{myurl}, key => $key }, { layout => undef },
    );

    sendmail($reply, { transport => $transport });
    debug( "Reply to ". $reply->header("To") ." send\n");
}

sub sendNotify {

    if (defined session('selfrom') and defined session('row')) {

        my $row = session('row');
        my $selfrom = session('selfrom');
        my @RCPT = split /\r?\n/, session('recipients');
        my @rcptlist;

        my $stm = database->prepare( config->{queries}{all} );
        $stm->execute();
        my $all = $stm->fetchall_hashref('email');

        for my $m (keys %$all) {

            if (($selfrom eq "provincie" and defined $all->{$m}->{provincie} and grep(/^$all->{$m}->{provincie}$/, @RCPT)) or
                ($selfrom eq "gemeente" and defined $all->{$m}->{gemeente} and grep(/^$all->{$m}->{gemeente}$/, @RCPT))) {

                my $addr = "$all->{$m}->{voornaam}";
                $addr .= " $all->{$m}->{tussenvoegsel}" if defined $all->{$m}->{tussenvoegsel};
                $addr .= " $all->{$m}->{achternaam}" if defined $all->{$m}->{achternaam};
                $addr .= "\tuit: $all->{$m}->{gemeente}, $all->{$m}->{provincie}\n";
                push @rcptlist, ($addr);
            }
        }
        if ($selfrom eq "lists") {

            for (@RCPT) {
                push @rcptlist, (sprintf "%s\t%s\n", $_, config->{lists}{$_}) if defined config->{lists}{$_};
            }
        }

        my $transport = Email::Sender::Transport::SMTP->new({
            host => config->{smtp}{host},
            ssl => config->{smtp}{ssl},
            sasl_username => config->{smtp}{user},
            sasl_password => config->{smtp}{pass},
        });
        my $reply = Email::Simple->create(
            header => [
                To      => config->{authorize_by},
                From    => $row->{from_address},
                Subject => "Te versturen mailing: " . $row->{subject},
            ],
            body => template 'sendntfy', { myurl => config->{myurl},
                                           ackkey => $row->{ackkey},
                                           selfrom => $selfrom,
                                           rcpt => \@RCPT,
                                           addr => \@rcptlist }, { layout => undef },
        );

        sendmail($reply, { transport => $transport });
        debug("Authorization request to ". $reply->header("To") ." send\n");
    } else {
        debug("Authorization request not send\n");
    }
}


true;

__END__
        if ( defined config->{email}{trans} and config->{email}{trans} eq 'smtp' ) {
            $transport = Email::Sender::Transport::SMTP->new({
                host => config->{smtp}{host},
                ssl => config->{smtp}{ssl},
                sasl_username => config->{smtp}{user},
                sasl_password => config->{smtp}{pass},
            });
        } else {
            $transport = Email::Sender::Transport::Mbox->new();
        }
