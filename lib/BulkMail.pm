package BulkMail;
use utf8;
use Dancer ':syntax';
use HTML::Entities;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Simple::Creator;
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

    for my $table ( @{ config->{sqlite}{tables} } ) {
        $db->do($table->{schema}) or die $db->errstr;
    }
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
            unless ($stm->execute(param('afz'),session->{key})) {
                template 'index', { error => "Fout in update afzender adres" };
                return;
            }

            $checked = param('afz');
            $row->{new_from_address} = param('afz');
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

    if (defined params->{afz} and defined session->{key}) {

        my $db = connect_db();
        my $stm = $db->prepare("select * from mbox where key = ?");
        $stm->execute(session->{key});

        if (my $row = $stm->fetchrow_hashref()) {
            # update sqlite database
            my $stm2 = $db->prepare( config->{sqlite}{update_from} );
            unless ($stm2->execute(param('afz'),session->{key})) {

                template 'index', { error => "Fout in update afzender adres" };
                return;
            }

            my @list = sort keys %{ config->{list} };

            template 'recipients', {subject => encode_entities($row->{subject}),
                                    from => encode_entities($row->{from_address}),
                                    new_from => encode_entities(param('afz')),
                                    list => \@list};
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
        my $stm = $db->prepare("select * from mbox where key = ?");
        $stm->execute(session->{key});

        if (my $row = $stm->fetchrow_hashref()) {

            my $stm2 = $db->prepare( config->{sqlite}{update_rcpt} );
            my $recipientlist;

            if (my $file = request->upload("file")) {

                $recipientlist = checkemail($file->content);
                debug("Recipients: " .$recipientlist);

            } 
            if (defined params->{adreslijst}) {

                $recipientlist .= ", " if $recipientlist;
                $recipientlist .= checkemail(params->{adreslijst});

            }

            if ($recipientlist) {

                unless ($stm2->execute($recipientlist,session->{key})) {
                    template 'index', { error => "Fout in update ontvanger adressen" };
                    return;
                }
                $row->{recipients} = $recipientlist;
                sendNotify($row);
                template 'submit', {subject => encode_entities($row->{subject}),
                                    from => encode_entities($row->{from_address}),
                                    new_from => encode_entities($row->{new_from_address}),
                                    authorize_by => encode_entities( config->{authorize_by} ),
                                    rcpt => encode_entities( $recipientlist )}

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
    my $stm = $db->prepare("select * from mbox where ackkey = ?");
    $stm->execute(param('ackkey'));
    if (my $row = $stm->fetchrow_hashref()) {

        my $message;
        if (defined param('examplemail')) {

            examplemail( config->{authorize_by}, $row );
            $message = "Voorbeeld mail verzonder naar ". config->{authorize_by};
        }

        session ackkey => param('ackkey');
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

post '/done' => sub {

    if (defined session->{ackkey}) {

        my $db = connect_db();
        my $stm = $db->prepare("select * from mbox where ackkey = ?");
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
                              new_from => encode_entities($row->{new_from_address})};
        } else {
            template 'index', { error => "Key niet gevonden in database" };
        }
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

    my $reply = Email::Simple->create(
        header => [
            To      => $to,
            From    => $row->{new_from_address},
            Subject => $row->{subject},
            'Content-Type' => $row->{content_type},
        ],
        body => $row->{body},
    );

    sendmail($reply, { transport => transport() });
    debug( "Example to ". $reply->header("To") ." send\n");
}

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

    sendmail($reply, { transport => transport() });
    debug( "Reply to ". $reply->header("To") ." send\n");
}

sub sendNotify {

    my $row = shift;
    if (defined $row) {

        my @rcptlist = split /, /, $row->{recipients};

        my $reply = Email::Simple->create(
            header => [
                To      => config->{authorize_by},
                From    => $row->{from_address},
                Subject => "Te versturen mailing: " . $row->{subject},
            ],
            body => template 'sendntfy', { myurl => config->{myurl},
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

        my @RCPT = Email::Address::XS->parse($mail->{recipients});
        my ($failed, $delivered) = ('','');
        my $std = $db->prepare( config->{sqlite}{update_delivered} );
        my $stf = $db->prepare( config->{sqlite}{update_failed} );

        for (@RCPT) {
            my $to = $_->format();
            my $reply = Email::Simple->create(
                header => [
                    To      => $to,
                    From    => $mail->{new_from_address},
                    Subject => $mail->{subject},
                    'Content-Type' => $mail->{content_type},
                ],
                body => $mail->{body},
            );

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
                From    => 'Bulk mailer <bulk@bulkmail.ict-sys.tudelft.nl>',
                Cc      => config->{authorize_by},
                Subject => "Bulkmail rapport",
            ],
            body => template 'report', {
                from => $mail->{from_address},
                new_from => $mail->{new_from_address},
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

