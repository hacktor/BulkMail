#!/usr/bin/env perl
use utf8;
use Dancer;
use BulkMail;
use threads;
use Net::POP3;
use Email::Simple;

# create a thread polling for new mail
threads->create(sub { 

    my $db = BulkMail::init_db();
    my $st = $db->prepare( config->{sqlite}{insert} );

    for (;;) {
        eval {
            my $pop = Net::POP3->new(config->{pop3}{host}, SSL => 1, SSL_verify_mode => 0, SSL_ca_file => config->{pop3}{ca});
            if (defined $pop and $pop->login(config->{pop3}{user}, config->{pop3}{pass}) > 0) {
        
                my $msgnums = $pop->list; # hashref of msgnum => size
                foreach my $msgnum (keys %$msgnums) {
        
                    my $email = Email::Simple->new(join '', @{ $pop->get($msgnum) });
                    my $key = makeKey();
                    my $ackkey = makeKey();
                    $st->execute($key,$ackkey,$email->header("From"),$email->header("Subject"),$email->header("Date"),$email->header("Content-Type"),$email->body);
                    BulkMail::sendReceipt($email,$key);
        
                    $pop->delete($msgnum) or warn("Delete failed");
                    $pop->quit;
                }
            } elsif (not defined $pop) {
                warning("POP3 connection fail");
            } else {
                $pop->quit;
            }
        };
        warn($@) if $@;
        sleep 30;
    }
})->detach();

dance;

### helper subs ###

sub makeKey {
    my @chars = ('0'..'9', 'A'..'Z');
    my $len = 64;
    my $string;
    while($len--){ $string .= $chars[rand @chars] };
    $string;
}

