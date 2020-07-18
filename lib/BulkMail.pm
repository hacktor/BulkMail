package BulkMail;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use HTML::Entities;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Simple::Creator;
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
        my $stm = $db->prepare("update mbox set new_from_address = ? where key = ?");
        unless ($stm->execute(param('afz'),session('key'))) {
            template 'index', { error => "Fout in update afzender adres" };
            return;
        }
        session->{row}{new_from_address} = param('afz');
        my $row = session('row');
        my $st1 = database->prepare( config->{queries}{provs} );
        my $st2 = database->prepare( config->{queries}{cities} );

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
        my $stm = $db->prepare("update mbox set table = ?, recipients = ? where key = ?");

        if (defined params->{provSubmit} and defined params->{provarea}) {

            session selfrom => "provincie";
            session recipients => params->{provarea};
            $stm->execute("provincie", params->{provarea}, $row->{key});

            template 'submit', {subject => encode_entities($row->{subject}),
                                date => encode_entities($row->{date}),
                                new_from => encode_entities($row->{new_from_address}),
                                selfrom => "provincie",
                                auth_by => encode_entities( config->{auth_by} ),
                                recipients => encode_entities(params->{provarea})}

        } elsif (defined params->{citySubmit} and defined params->{cityarea}) {

            session selfrom => "gemeente";
            session recipients => params->{cityarea};
            $stm->execute("gemeente", params->{cityarea}, $row->{key});

            template 'submit', {subject => encode_entities($row->{subject}),
                                date => encode_entities($row->{date}),
                                new_from => encode_entities($row->{new_from_address}),
                                selfrom => "gemeente",
                                auth_by => encode_entities( config->{auth_by} ),
                                recipients => encode_entities(params->{cityarea})}

        } elsif (defined params->{listSubmit} and defined params->{listarea}) {

            session selfrom => "lists";
            session recipients => params->{listarea};
            $stm->execute("lists", params->{listarea}, $row->{key});

            template 'submit', {subject => encode_entities($row->{subject}),
                                date => encode_entities($row->{date}),
                                new_from => encode_entities($row->{new_from_address}),
                                selfrom => "lists",
                                auth_by => encode_entities( config->{auth_by} ),
                                recipients => encode_entities(params->{listarea})}
        } else {
            template 'index', { error => "Error in submitted form" };
        }
    } else {
        template 'index', { error => "Session key not found" };
    }
};

any ['get', 'post'] => '/' => sub {
    template 'index';
};

sub sendReceipt {

    my ($email,$key) = @_;
    my $reply = Email::Simple->create(
        header => [
            To      => $email->header("From"),
            From    => $email->header("To"),
            Subject => "Ontvangen: " . $email->header("Subject"),
        ],
        body => template 'sendrcpt', { myurl => config->{myurl}, key => $key }, { layout => undef },
    );

    sendmail($reply);
    print "Reply to ". $reply->header("To") ." send\n";
}

sub sendNotify {

    if (defined session('table') and defined session('row')) {

        my $row = session('row');
        my $table = session('table');

        my $reply = Email::Simple->create(
            header => [
                To      => config->{auth_by},
                From    => $row->{from_address},
                Subject => "Te versturen mailing: " . $row->{subject},
            ],
            body => template 'sendntfy', { myurl => config->{myurl},
                                           ackkey => $row->{ackkey},
                                           table => $table }, { layout => undef },
        );

        sendmail($reply);
        print "Reply to ". $reply->header("To") ." send\n";
    }
}


true;
