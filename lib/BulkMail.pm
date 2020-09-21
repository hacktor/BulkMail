package BulkMail;
use utf8;
use Dancer ':syntax';
use HTML::Entities;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Simple::Creator;
use Email::Sender::Transport::Mbox;
use Email::Sender::Transport::SMTP;
use Email::Address::XS qw(parse_email_addresses format_email_addresses);
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

    $db->do( config->{sqlite}{schema} ) or die $db->errstr;
    return $db;
}

sub flatten {
  map { ref $_ ? flatten(@{$_}) : $_ } @_;
}

any ['get', 'post'] => '/mailing/:key' => sub {

    my $db = connect_db();
    my $stm = $db->prepare("select * from mbox where key = ?");
    $stm->execute(param('key'));

    if (my $row = $stm->fetchrow_hashref()) {

        my $message;
        my $checked = $row->{from_address};
        if (defined param('afz') and defined param('examplemail')) {

            my $stm = $db->prepare( config->{sqlite}{update_from} );
            unless ($stm->execute(param('afz'),session('key'))) {
                template 'index', { error => "Fout in update afzender adres" };
                return;
            }

            $checked = param('afz');
            session->{row}{new_from_address} = param('afz');
            examplemail($row->{from_address});
            $message = "Voorbeeld mail verzonder naar $row->{from_address}";
        }
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
                             message => encode_entities($message),
                             checked => encode_entities($checked),
                             froms => \@froms};

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

        my @list = sort keys %{ config->{list} };

        template 'recipients', {subject => encode_entities($row->{subject}),
                                from => encode_entities($row->{from_address}),
                                new_from => encode_entities($row->{new_from_address}),
                                list => \@list};
    } else {
        template 'index', { error => "Fout in nieuw afzender adres" };
    }
};

post '/submit' => sub {

    if (defined session('row')) {

        my $db = connect_db();
        my $stm = $db->prepare( config->{sqlite}{update_rcpt} );
        my $recipientlist;

        if (my $file = request->upload("file")) {

            $recipientlist = checkemail($file->content);
            session->{row}{recipients} = $recipientlist;
            debug("Recipients: " .$recipientlist);

        } 
        if (defined params->{adreslijst}) {

            $recipientlist .= ", " if $recipientlist;
            $recipientlist .= checkemail(params->{adreslijst});
            session->{row}{recipients} = $recipientlist;

        }
        my $row = session->{row};

        if ($recipientlist) {

            unless ($stm->execute($recipientlist,session('key'))) {
                template 'index', { error => "Fout in update ontvanger adressen" };
                return;
            }
            sendNotify();
            template 'submit', {subject => encode_entities($row->{subject}),
                                from => encode_entities($row->{from_address}),
                                new_from => encode_entities($row->{new_from_address}),
                                authorize_by => encode_entities( config->{authorize_by} ),
                                rcpt => encode_entities( session->{row}{recipients} )}

        } else {
            template 'index', { error => "Error in formulier, geen ontvangers gevonden" };
        }

    } else {
        template 'index', { error => "Sessie key niet gevonden" };
    }
};

any ['get', 'post'] => '/submitted/:ackkey' => sub {

    my $db = connect_db();
    my $stm = $db->prepare("select * from mbox where ackkey = ?");
    $stm->execute(param('ackkey'));
    if (my $row = $stm->fetchrow_hashref()) {

        my $message;
        if (defined param('examplemail')) {

            examplemail( config->{authorize_by} );
            $message = "Voorbeeld mail verzonder naar ". config->{authorize_by};
        }

        session ackkey => param('ackkey');
        session row => $row;
        template 'submitted', {subject => encode_entities($row->{subject}),
                               from => encode_entities($row->{from_address}),
                               new_from => encode_entities($row->{new_from_address}),
                               rcpt => encode_entities($row->{recipients}),
                               message => encode_entities($message),
                               body => encode_entities($row->{body})};

    } else {
        template 'index', { error => "Key niet gevonden" };
    }
};

any qr{.*} => sub {
    status 'not_found';
    template 'index', { error => "404 Niet gevonden" };
};

sub checkemail {

    # evaluate email addresses by parsing and formatting
    my $recipients = shift;
    $recipients =~ s/\r?\n/, /g;
    my @RCPT = Email::Address::XS->parse($recipients);
    my @parsed;
    for my $email (@RCPT) {
        push @parsed, $email->{original} unless defined $email->{invalid};
    }
    return join ', ', @parsed;
}

sub examplemail {

    my $to = shift;
    my $row = session->{row};
    my @RCPT = split /\r?\n/, session('recipients');
    my @rcptlist;

    my $transport = Email::Sender::Transport::SMTP->new({
        host => config->{smtp}{host},
        ssl => config->{smtp}{ssl},
        SSL_verify_mode => SSL_VERIFY_NONE,
        sasl_username => config->{smtp}{user},
        sasl_password => config->{smtp}{pass},
    });
    my $reply = Email::Simple->create(
        header => [
            To      => $to,
            From    => session->{row}{new_from_address},
            Subject => $row->{subject},
        ],
        body => $row->{body},
    );

    sendmail($reply, { transport => $transport });
    debug( "Example to ". $reply->header("To") ." send\n");
}

sub sendReceipt {

    my ($email,$key) = @_;

    my $transport = Email::Sender::Transport::SMTP->new({
        host => config->{smtp}{host},
        ssl => config->{smtp}{ssl},
        SSL_verify_mode => SSL_VERIFY_NONE,
        sasl_username => config->{smtp}{user},
        sasl_password => config->{smtp}{pass},
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

    if (defined session('row')) {

        my $row = session('row');
        my @RCPT = split /\r?\n/, session('recipients');
        my @rcptlist;

        my $transport = Email::Sender::Transport::SMTP->new({
            host => config->{smtp}{host},
            ssl => config->{smtp}{ssl},
            SSL_verify_mode => SSL_VERIFY_NONE,
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
