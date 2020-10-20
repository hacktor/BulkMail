package BulkMail;
use utf8;
use Dancer ':syntax';
use HTML::Entities;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Simple::Creator;
use Email::Sender::Transport::SMTP;
use Email::Address::XS qw(parse_email_addresses format_email_addresses);
use Spreadsheet::Read;
use IO::Socket::SSL;
use DBI;
use Data::Dumper;

our $VERSION = '0.2';

sub connect_db {
  my $db = DBI->connect("dbi:SQLite:dbname=".config->{sqlite}{db}) or
     die $DBI::errstr;

  return $db;
}

sub init_db {
    my $db = connect_db();

    for my $table ( @{ config->{sqlite}{tables} } ) {
        $db->do($table->{schema}) or die $db->errstr;
    }
}

any ['get', 'post'] => '/mailing/:key' => sub {

    my $db = connect_db();
    my $stm = $db->prepare( config->{sqlite}{get_mail} );
    $stm->execute(param('key'));

    if (my $row = $stm->fetchrow_hashref()) {

        my $message;
        my $checked = $row->{from_address};
        if (defined param('replyto') and defined param('examplemail')) {

            my $name = (defined param('name')) ? param('name') : config->{myname};
            my $stm = $db->prepare( config->{sqlite}{update_from} );
            unless ($stm->execute(param('replyto'),$name,session->{key})) {
                template 'index', { error => "Fout in update afzender" };
                return;
            }

            $checked = param('replyto');
            $row->{replyto} = param('replyto');
            $row->{from_name} = $name;
            examplemail($row->{from_address},$row);
            $message = "Voorbeeld mail verzonder naar $row->{from_address}";
        }
        my @froms;
        for my $from (@{config->{froms}}) {
            push @froms, encode_entities($from);
        }

        session key => param('key');
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

    if (defined params->{replyto} and defined session->{key}) {

        my $db = connect_db();
        my $stm = $db->prepare( config->{sqlite}{get_mail} );
        $stm->execute(session->{key});

        if (my $row = $stm->fetchrow_hashref()) {
            # update sqlite database
            my $name = (defined params->{name}) ? params->{name} : config->{myname};
            my $stu = $db->prepare( config->{sqlite}{update_from} );
            unless ($stu->execute(param('replyto'),$name,session->{key})) {

                template 'index', { error => "Fout in update afzender adres" };
                return;
            }

            my $from = Email::Address::XS->new($row->{from_name}, config->{myfrom});
            template 'recipients', {subject => encode_entities($row->{subject}),
                                    from => encode_entities($row->{from_address}),
                                    new_from => encode_entities($from->format()),
                                    replyto => encode_entities(param('replyto'))};
        } else {

            template 'index', { error => "Fout in nieuw afzender adres" };
        }
    } else {
        template 'index', { error => "Fout in nieuw afzender adres" };
    }
};

post '/submit' => sub {

    if (defined session->{key}) {

        my $db = connect_db();
        my $stm = $db->prepare( config->{sqlite}{get_mail} );
        $stm->execute(session->{key});

        if (my $row = $stm->fetchrow_hashref()) {

            my $stu = $db->prepare( config->{sqlite}{update_rcpt} );
            my $chkres;

            if (defined params->{adreslijst}) {

                my @list = split /\r?\n/, params->{adreslijst};
                $chkres= checkemail(@list);

            }
            if (my $file = request->upload("text")) {

                my @list = split /\r?\n/, $file->content;
                $chkres = checkemail(@list);

            } 
            if (my $file = request->upload("spread")) {

                $chkres = checkemail(firstcolumn($file));

            }

            my $rcptstr = join ', ', values %{$chkres->{recipients}} if ref $chkres->{recipients} eq "HASH";
            my $dblestr = join ', ', values %{$chkres->{doubles}} if ref $chkres->{doubles} eq "HASH";
            my $invastr = join ', ', @{$chkres->{invalid}} if ref $chkres->{invalid} eq "ARRAY";
            debug("Recipients: " . $rcptstr);
            debug("Doubles: " . $dblestr);
            debug("Invalid: " . $invastr);

            if ($rcptstr) {

                unless ($stu->execute($rcptstr,$dblestr,$invastr,session->{key})) {
                    template 'index', { error => "Fout in update ontvanger adressen" };
                    return;
                }
                $row->{recipients} = $rcptstr;
                sendNotify($row);
                template 'submit', {subject => encode_entities($row->{subject}),
                                    from => encode_entities($row->{from_address}),
                                    name => encode_entities($row->{from_name} ." <". config->{myfrom} .">"),
                                    replyto => encode_entities($row->{replyto}),
                                    authorize_by => encode_entities( config->{authorize_by} ),
                                    rcptnr => scalar %{$chkres->{recipients}},
                                    dblenr => scalar %{$chkres->{doubles}},
                                    invanr => scalar @{$chkres->{invalid}},
                                    double => encode_entities( $dblestr ),
                                    invalid => encode_entities( $invastr )}

            } else {
                template 'index', { error => "Error in formulier, geen ontvangers gevonden" };
            }
        } else {
            template 'index', { error => "Sessie key niet gevonden in database" };
        }
    } else {
        template 'index', { error => "Sessie key niet gevonden" };
    }
};

any ['get', 'post'] => '/submitted/:ackkey' => sub {

    my $db = connect_db();
    my $stm = $db->prepare( config->{sqlite}{get_mail_byack} );
    $stm->execute(param('ackkey'));
    if (my $row = $stm->fetchrow_hashref()) {

        my $message;
        if (defined param('examplemail')) {

            examplemail( config->{authorize_by}, $row );
            $message = "Voorbeeld mail verzonder naar ". config->{authorize_by};
        }

        session ackkey => param('ackkey');
        my $from = Email::Address::XS->new($row->{from_name}, config->{myfrom});
        template 'submitted', {subject => encode_entities($row->{subject}),
                               from => encode_entities($row->{from_address}),
                               new_from => encode_entities($from->format()),
                               replyto => encode_entities($row->{replyto}),
                               rcpt => encode_entities($row->{recipients}),
                               message => encode_entities($message),
                               body => encode_entities($row->{body})};

    } else {
        template 'index', { error => "Key niet gevonden" };
    }
};

post '/done' => sub {

    if (defined session->{ackkey}) {

        my $db = connect_db();
        my $stm = $db->prepare( config->{sqlite}{get_mail_byack} );
        $stm->execute(session->{ackkey});

        if (my $row = $stm->fetchrow_hashref()) {

            # store the mailing to be picked up by the mailer thread
            $stm = $db->prepare(config->{sqlite}{insert_mailing});
            unless ($stm->execute($row->{key})) {
                template 'index', { error => "Fout in klaarzetten mailing" };
                return;
            }

            template 'done', {subject => encode_entities($row->{subject}),
                              from => encode_entities($row->{from_address}),
                              new_from => encode_entities($row->{replyto})};
        } else {
            template 'index', { error => "Key niet gevonden in database" };
        }
    } else {
        template 'index', { error => "Key niet gevonden" };
    }
};

any ['get', 'post'] => '/admin' => sub {

    if (defined param('user') and defined param('pass') and
            param('user') eq config->{admin}{user} and param('pass') eq config->{admin}{pass} ) {
        session 'login' => 1;
    }
    if (defined session->{login}) {

        # gather data
        my $db = connect_db();
        my $stm = $db->prepare( config->{sqlite}{get_mailings} );
        $stm->execute(0);
        my $ready = $stm->fetchall_hashref('id');
        $stm->execute(1);
        my $busy = $stm->fetchall_hashref('id');
        $stm->execute(2);
        my $done = $stm->fetchall_hashref('id');

        $stm = $db->prepare( config->{sqlite}{get_all} );
        $stm->execute();
        my $all = $stm->fetchall_hashref('id');

        template 'admin', {ready => $ready, busy => $busy, done => $done, all => $all};
    } else {
        template 'adminlogin', {};
    }
};

any qr{.*} => sub {
    status 'not_found';
    template 'index', { error => "404 Niet gevonden" };
};

sub checkemail {

    # evaluate email addresses by parsing and formatting
    my @rcpt = @_;
    my ($recipients,$doubles,$invalid) = ({},{},[]);
    my @parsed = Email::Address::XS->parse(join ', ', @rcpt);
    for my $email (@parsed) {
        if (defined $email->{invalid}) {
            push @$invalid, $email->{original};
        } elsif ($recipients->{$email->address}) {
            $doubles->{$email->address} = $email->format();
        } else {
            $recipients->{$email->address} = $email->format();
        }
    }
    return { recipients => $recipients, doubles => $doubles, invalid => $invalid };
}

sub firstcolumn {
    my $file = shift;
    (my $ext = $file->filename) =~ s/.*\.//;
    if (grep /^$ext$/, @{ config->{extensions} }) {
        my $book = ReadData($file->content, parser => $ext);
        my $col = $book->[1]{cell}[1];
        shift @$col;
        return @$col;
    }
}

sub transport {

    # return Email::Sender::Transport object
    if (defined config->{smtp}{ssl} and config->{smtp}{ssl}) {

        return Email::Sender::Transport::SMTP->new({
            host => config->{smtp}{host},
            ssl => config->{smtp}{ssl},
            SSL_verify_mode => SSL_VERIFY_NONE,
            sasl_username => config->{smtp}{user},
            sasl_password => config->{smtp}{pass}, });
    } else {

        return Email::Sender::Transport::SMTP->new({
            host => config->{smtp}{host}});
    }
}

sub examplemail {

    my $to = shift;
    my $row = shift;
    my $from = Email::Address::XS->new($row->{from_name}, config->{myfrom});

    my $reply = Email::Simple->create(
        header => [
            To      => $to,
            From    => $from->format(),
            Subject => $row->{subject},
            'Reply-To' => $row->{replyto},
        ],
        body => $row->{body},
    );
    for my $header (@{ config->{saveheaders} }) {
        (my $h = $header) =~ s/_/-/g; 
        $reply->header_raw_set($h, $row->{$header}) if $row->{$header};
    }

    sendmail($reply, { transport => transport() });
    debug( "Example to ". $reply->header("To") ." send\n");
}

sub sendReceipt {

    my ($email,$key) = @_;

    my $reply = Email::Simple->create(
        header => [
            To      => $email->header("From"),
            From    => config->{myfrom},
            Subject => "Ontvangen: " . $email->header("Subject"),
        ],
        body => template 'sendrcpt', { myurl => config->{myurl}, key => $key }, { layout => undef },
    );

    sendmail($reply, { transport => transport() });
    debug( "Reply to ". $reply->header("To") ." send\n");
}

sub sendNotify {

    my $row = shift;
    if (defined $row) {

        my @rcptlist = split /, /, $row->{recipients};
        my $fromname = Email::Address::XS->new($row->{from_name}, config->{myfrom});

        my $reply = Email::Simple->create(
            header => [
                To      => config->{authorize_by},
                From    => config->{myfrom},
                Subject => "Te versturen mailing: " . $row->{subject},
            ],
            body => template 'sendntfy', { myurl => config->{myurl},
                                           from => $row->{from_address},
                                           replyto => $row->{replyto},
                                           name => $fromname->format(),
                                           subject => $row->{subject},
                                           ackkey => $row->{ackkey},
                                           addr => \@rcptlist }, { layout => undef },
        );

        sendmail($reply, { transport => transport() });
        debug("Authorization request to ". $reply->header("To") ." send\n");
    } else {
        debug("Authorization request not send\n");
    }
}

sub mailing {

    my $mailing = shift;
    return unless $mailing->{key};

    my $db = BulkMail::connect_db();
    my $sts = $db->prepare( config->{sqlite}{update_status} );
    unless ($sts->execute(1,$mailing->{key})) {
        debug("Mailing status update failed, not sending");
        return;
    }

    # get mail info
    my $stm = $db->prepare( config->{sqlite}{get_mail} );
    $stm->execute($mailing->{key});
    if (my $mail = $stm->fetchrow_hashref) {

        my @parsed = Email::Address::XS->parse($mail->{recipients});
        my ($failed, $delivered) = ('','');
        my $std = $db->prepare( config->{sqlite}{update_delivered} );
        my $stf = $db->prepare( config->{sqlite}{update_failed} );

        for (@parsed) {
            my $to = $_->format();
            my $from = Email::Address::XS->new($mail->{from_name}, config->{myfrom});
            my $reply = Email::Simple->create(
                header => [
                    To      => $to,
                    From    => $from->format(),
                    Subject => $mail->{subject},
                    'Reply-To' => $mail->{replyto},
                ],
                body => $mail->{body},
            );
            for my $header (@{ config->{saveheaders} }) {
                (my $h = $header) =~ s/_/-/g; 
                $reply->header_raw_set($h, $mail->{$header}) if $mail->{$header};
            }

            eval {
                sendmail($reply, { transport => transport() });
            };
            if ($@) {
                $failed .= ($failed) ? ", $to" : $to;
                $stf->execute($failed,$mailing->{key});
            } else {
                $delivered .= ($delivered) ? ", $to" : $to;
                $std->execute($delivered,$mailing->{key});
            }
            debug("Sent to ". $reply->header("To") ." send\n");
        }
        # update status to ready
        $sts->execute(2,$mailing->{key});

        # send report to author and authorizer
        my @F = split /, /, $failed;
        my @D = split /, /, $delivered;
        my $report = Email::Simple->create(
            header => [
                To      => $mail->{from_address},
                From    => config->{myfrom},
                Cc      => config->{authorize_by},
                Subject => "Bulkmail rapport",
            ],
            body => template 'report', {
                from => $mail->{from_address},
                new_from => $mail->{replyto},
                subject => $mail->{subject},
                nrfail => scalar @F,
                failed => \@F,
                nrdeliver => scalar @D,
                delivered => \@D }, { layout => undef },
        );
        eval {
            sendmail($report, { transport => transport() });
        };
        debug($@) if $@;
        debug("Report sent");
    }
}

true;

