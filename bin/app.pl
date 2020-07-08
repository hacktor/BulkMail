#!/usr/bin/env perl
use Dancer;
use BulkMail;
use threads;
use Net::POP3;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Simple::Creator;

# create a thread polling for new mail
threads->create(sub { 

    my $db = BulkMail::init_db();
    my $st = $db->prepare( config->{sqlite}{insert} );

    for (;;) {
        my $pop = Net::POP3->new(config->{email}{host}, SSL => 1, SSL_ca_file => config->{email}{ca});
        if (defined $pop and $pop->login(config->{email}{user}, config->{email}{pass}) > 0) {
    
            my $msgnums = $pop->list; # hashref of msgnum => size
            foreach my $msgnum (keys %$msgnums) {
    
                my $email = Email::Simple->new(join '', @{ $pop->get($msgnum) });
                my $key = makeKey();
                my $ackkey = makeKey();
                $st->execute($key,$ackkey,$email->header("From"),$email->header("Subject"),$email->header("Date"),$email->body);
                sendReceipt($email,$key);
    
                $pop->delete($msgnum);
            }
        } elsif (not defined $pop) {
            warning("POP3 connection fail");
        } else {
            $pop->quit;
        }
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

sub sendReceipt {

    my ($email,$key) = @_;
    my $reply = Email::Simple->create(
        header => [
            To      => $email->header("From"),
            From    => $email->header("To"),
            Subject => "Received: " . $email->header("Subject"),
        ],
        body => template 'body', { bulkurl => config->{bulkurl}, key => $key }, { layout => undef },
    );

    sendmail($reply);
    print "Reply to ". $reply->header("To") ." send\n";
}
