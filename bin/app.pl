#!/usr/bin/env perl
use utf8;
use Dancer;
use BulkMail;
use threads;
use Mail::IMAPClient;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Simple::Creator;
use Email::Sender::Transport::Mbox;
use Email::Sender::Transport::SMTP;
use Email::Address::XS qw(parse_email_addresses format_email_addresses);
use IO::Socket::SSL;

# initialize (create if not exists) database
BulkMail::init_db();

# create a thread polling for new mail
threads->create(sub { 

    my $db = BulkMail::connect_db();
    my $st = $db->prepare( config->{sqlite}{insert} );

    for (;;) {
        eval {
            my $imap = Mail::IMAPClient->new(
                Server   => config->{imap}{host},
                User     => config->{imap}{user},
                Password => config->{imap}{pass},
                Ssl => 1,
                Uid => 1,
                SSL_ca_file => config->{imap}{ca});

            if ($imap->select('INBOX')) {
        
                my $msgnums = $imap->messages; #array
                foreach my $msgnum (@$msgnums) {
        
                    my $email = Email::Simple->new($imap->message_string($msgnum));
                    my $key = makeKey();
                    my $ackkey = makeKey();
                    $st->execute($key,$ackkey,$email->header("From"),$email->header("Subject"),$email->header("Date"),$email->header("Content-Type"),$email->body);
                    BulkMail::sendReceipt($email,$key);

                    # move the mail to the 'DONE' folder
                    $imap->expunge if $imap->move( 'DONE', $msgnum );
        
                }

            } elsif (not defined $imap) {
                warning("IMAP connection fail");
            } else {
                warning("INBOX not found");
            }
            $imap->logout if $imap;
        };
        warn($@) if $@;
        sleep 30;
    }
})->detach();

# create another thread polling for authorized mailings
threads->create(sub {

    my $db = BulkMail::connect_db();
    my $stm = $db->prepare( config->{sqlite}{get_mailings} );

    for (;;) {
        # get mailings with status 0
        $stm->execute(0);
        mailing($_) for $stm->fetchrow_hashref;
        sleep 60;
    }
})->detach();

sub mailing {

    my $mailing = shift;
    return unless $mailing->{key};

    my $db = BulkMail::connect_db();
    $db->do( config->{sqlite}{update_status} );

    # get mail info
    my $stm = $db->prepare( config->{sqlite}{get_mail} );
    $stm->execute($mailing->{key});
    if (my $mail = $stm->fetchrow_hashref) {

        my @RCPT = Email::Address::XS->parse($mail->{recipients});
        my ($failed, $delivered);
        my $std = $db->prepare( config->{sqlite}{update_delivered} );
        my $stf = $db->prepare( config->{sqlite}{update_failed} );

        for (@RCPT) {
            my $to = $_->format();
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
                    From    => $mail->{new_from_address},
                    Subject => $mail->{subject},
                    'Content-Type' => $mail->{content_type},
                ],
                body => $mail->{body},
            );

            eval {
                sendmail($reply, { transport => $transport });
            };
            if ($@) {
                $failed .= ($failed) ? ", $to" : $to;
                $stf->execute($failed,$mailing->{key});
            } else {
                $delivered .= ($delivered) ? ", $to" : $to;
                $std->execute($delivered,$mailing->{key});
            }
            debug( "Sent to ". $reply->header("To") ." send\n");
        }
    }
}

dance;

### helper subs ###

sub makeKey {
    my @chars = ('0'..'9', 'A'..'Z');
    my $len = 64;
    my $string;
    while($len--){ $string .= $chars[rand @chars] };
    $string;
}

