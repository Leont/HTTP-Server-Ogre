use v6.c;
use HTTP::Server::Ogre::HTTP2::Frame;

class X::HTTP::Server::Ogre::HTTP2::Disconnect is Exception {
    method message() { "Connection unexpectedly closed in the middle of frame" }
}

class X::HTTP::Server::Ogre::HTTP2::IncorrectPreface is Exception {
    method message() { "Client's HTTP/2 preface value is incorrect" }
}

class HTTP::Server::Ogre::HTTP2::FrameParser {

    constant PREFACE = utf8.new(
        80, 82, 73, 32, 42, 32, 72, 84, 84, 80, 47, 50,
        46, 48, 13, 10, 13, 10, 83, 77, 13, 10, 13, 10
    );

    method parse-frames(Supply:D $in, $connection-state, --> Supply) {
        supply {
            my enum Expecting <Header Payload Preface>;

            my $buffer = Buf.new;
            my $missing-preface = True;
            my $length;
            my ($type, $flags, $sid);
            my Expecting $expecting = Header;

            whenever $in -> $packet {
                my $data = $buffer ~ $packet;
                $buffer = Buf.new;

                if $missing-preface {
                    if $data.subbuf(0,24) eq PREFACE {
                        start $connection-state.settings.emit(True);
                        $data .= subbuf(24);
                        $missing-preface = False;
                    } else {
                        die X::HTTP::Server::Ogre::HTTP2::IncorrectPreface.new;
                    }
                }

                loop {
                    $_ = $expecting;

                    when Header {
                        if $data.elems < 9 {
                            $buffer.append: $data; last;
                        } else {
                            $length = ($data[0] +< 16) +| ($data[1] +< 8) +| $data[2];
                            $type = $data[3];
                            $flags = $data[4];
                            $data[5] +&= 0x7F; # Reset first bit
                            $sid = ($data[5] +< 24) +| ($data[6] +< 16) +| ($data[7] +< 8) +| $data[8];
                            $data .= subbuf(9); # Header is parsed;
                            $expecting = Payload; next;
                        }
                    }
                    when Payload {
                        if $data.elems >= $length {
                            my $result = payload($type, $data, $length, :$flags, stream-identifier => $sid);
                            if $result ~~ HTTP::Server::Ogre::HTTP2::Frame::Settings {
                                (start $connection-state.settings.emit($result)) unless $flags +& 1;
                            } elsif $result ~~ HTTP::Server::Ogre::HTTP2::Frame::Ping {
                                start $connection-state.ping.emit($result);
                            } else {
                                emit $result;
                            }
                            $data .= subbuf($length);
                            $expecting = Header; next if $data.elems > 0;
                        } else {
                            $buffer.append: $data;
                        }
                    }
                }
                LAST {
                    die X::HTTP::Server::Ogre::HTTP2::Disconnect.new if $expecting != Header;
                }
            }
        }
    }

    my multi sub payload(0, Buf $data is rw, $length, *%header) {
        my $padded = %header<flags> +& 0x8 == 0x8;
        my $padding-length = $data[0] if $padded;
        with $padding-length {
            die X::HTTP::Server::Ogre::HTTP2::Error.new(code => PROTOCOL_ERROR) if $_ >= $length;
        }
        my $payload = $padded
        # `-1` here is first byte that is padding-length
        ?? $data.subbuf(1, $length - $padding-length - 1)
        !! $data.subbuf(0, $length);
        HTTP::Server::Ogre::HTTP2::Frame::Data.new(padding-length => ($padding-length // UInt),
                                    data => utf8.new($payload), |%header);
    }
    my multi sub payload(1, Buf $data is rw, $length, *%header) {
        my $padded = %header<flags> +& 0x8 == 0x8;
        my $priority = %header<flags> +& 0x8 == 0x20;
        my $padding-length = $data[0] if $padded;
        with $padding-length {
            die X::HTTP::Server::Ogre::HTTP2::Error.new(code => PROTOCOL_ERROR) if $_ >= $length;
        }
        my $payload = $padded
        # `-1` here is first byte that is padding-length
        ?? $data.subbuf(1, $length - $padding-length - 1)
        !! $data.subbuf(0, $length);
        my ($dependency, $weight, $headers, $exclusive);
        if $priority {
            $exclusive = $payload[0] +& (1 +< 7) != 0;
            if $exclusive {
                $dependency = ($data[0] +< 24) +| ($data[1] +< 16) +| ($data[2] +< 8) +| $data[3];
                $weight = $data[4];
            }
        } else {
            $exclusive = False;
        }
        $headers = Buf.new: $payload.subbuf($exclusive ?? 5 !! 0, $length);
        HTTP::Server::Ogre::HTTP2::Frame::Headers.new(padding-length => $padding-length // UInt,
                                       dependency => $dependency // UInt,
                                       weight => $weight // UInt,
                                       connection => %header<conn>,
                                       :$exclusive, :$headers, |%header);
    }
    my multi sub payload(2, Buf $data is rw, $length, *%header) {
        die X::HTTP::Server::Ogre::HTTP2::Error.new(code => FRAME_SIZE_ERROR) if $length != 5;
        my $exclusive = $data[0] +& (1 +< 7) != 0;
        $data[0] +&= 0x7F; # Reset first bit.
        my $dep = ($data[0] +< 24) +| ($data[1] +< 16) +| ($data[2] +< 8) +| $data[3];
        my $weight = $data[4];
        HTTP::Server::Ogre::HTTP2::Frame::Priority.new(:$exclusive, dependency => $dep, :$weight, |%header);
    }
    my multi sub payload(3, Buf $data is rw, $length, *%header) {
        die X::HTTP::Server::Ogre::HTTP2::Error.new(code => FRAME_SIZE_ERROR) if $length != 4;
        my $error-code = ($data[0] +< 24) +| ($data[1] +< 16) +| ($data[2] +< 8) +| $data[3];
        $error-code = ErrorCode($error-code) // INTERNAL_ERROR;
        HTTP::Server::Ogre::HTTP2::Frame::RstStream.new(:$error-code, |%header);
    }
    my multi sub payload(4, Buf $data is rw, $length, *%header) {
        die X::HTTP::Server::Ogre::HTTP2::Error.new(code => FRAME_SIZE_ERROR) if %header<flags> == 1 && $length != 0;
        die X::HTTP::Server::Ogre::HTTP2::Error.new(code => FRAME_SIZE_ERROR) if $length % 6 != 0;
        my $sets = $length div 6;
        my @settings;

        for 0...($sets-1) {
            last if $sets == 0;
            my $identifier = ($data[$_*6 + 0] +< 8) +| $data[$_*6 + 1];
            my $value = ($data[$_*6 + 2] +< 24) +| ($data[$_*6 + 3] +< 16) +| ($data[$_*6 + 4] +< 8) +| $data[$_*6 + 5];
            @settings.append: $identifier => $value;
        }
        HTTP::Server::Ogre::HTTP2::Frame::Settings.new(:@settings, |%header);
    }
    my multi sub payload(5, Buf $data is rw, $length, *%header) {
        my $padded = %header<flags> +& 0x8 == 0x8;
        my $padding-length = $data[0] if $padded;
        my $payload = $padded
        # `-1` here is first byte that is padding-length
        ?? $data.subbuf(1, $length - $padding-length - 1)
        !! $data.subbuf(0, $length);
        my ($promised-sid, $headers);

        $payload[0] = $payload[0] +& 0x79; # Reset first bit.
        $promised-sid = ($payload[0] +< 24)
                     +| ($payload[1] +< 16)
                     +| ($payload[2] +< 8)
                     +|  $payload[3];
        $headers = utf8.new: $payload.subbuf(4, $length);
        HTTP::Server::Ogre::HTTP2::Frame::PushPromise.new(padding-length => ($padding-length // UInt),
                                           :$promised-sid, :$headers, |%header);
    }
    my multi sub payload(6, Buf $data is rw, $length, *%header) {
        my $payload = Blob.new($data.subbuf(0, $length));
        HTTP::Server::Ogre::HTTP2::Frame::Ping.new(:$payload, |%header);
    }
    my multi sub payload(7, Buf $data is rw, $length, *%header) {
        my ($last-sid, $error-code, $debug);
        $data[0] = $data[0] +& 0x79; # Reset first bit.
        $last-sid = ($data[0] +< 24)
                 +| ($data[1] +< 16)
                 +| ($data[2] +< 8)
                 +|  $data[3];
        $error-code = ($data[4] +< 24)
                   +| ($data[5] +< 16)
                   +| ($data[6] +< 8)
                   +|  $data[7];
        $error-code = ErrorCode($error-code) // INTERNAL_ERROR;
        $debug = utf8.new: $data.subbuf(8, $length);
        HTTP::Server::Ogre::HTTP2::Frame::GoAway.new(:$last-sid, :$error-code, :$debug, |%header);
    }
    my multi sub payload(8, Buf $data is rw, $length, *%header) {
        die X::HTTP::Server::Ogre::HTTP2::Error.new(code => FRAME_SIZE_ERROR) if $length != 4;
        my $increment = ($data[0] +< 24)
                 +| ($data[1] +< 16)
                 +| ($data[2] +< 8)
                 +|  $data[3];
        HTTP::Server::Ogre::HTTP2::Frame::WindowUpdate.new(:$increment, |%header);
    }
    my multi sub payload(9, Buf $data is rw, $length, *%header) {
        my $headers = utf8.new: $data.subbuf(0, $length);
        HTTP::Server::Ogre::HTTP2::Frame::Continuation.new(:$headers, |%header);
    }
    my multi sub payload($unknown, Buf $data is rw, $length, *%header) {
        my $payload = utf8.new: $data.subbuf(0, $length);
        HTTP::Server::Ogre::HTTP2::Frame::Unknown.new(:$payload, |%header);
    }
}

