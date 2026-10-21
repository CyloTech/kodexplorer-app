<?php
/* Minimal FastCGI client used by the regression checks to talk to php-fpm7.2
 * directly, the way nginx does.
 *
 * Usage: php7.2 fcgi.php <host> <port> <body-file|-> [NAME=VALUE ...]
 *
 * Prints the response body (CGI headers removed) on stdout and any FastCGI
 * stderr records on stderr.
 * Exit status: 0 the request completed (END_REQUEST received)
 *              2 could not connect
 *              3 the worker closed the connection before END_REQUEST
 */

if ($argc < 4) {
    fwrite(STDERR, "usage: fcgi.php <host> <port> <body-file|-> [NAME=VALUE ...]\n");
    exit(64);
}
list(, $host, $port, $bodyFile) = $argv;
$params = array();
foreach (array_slice($argv, 4) as $pair) {
    $eq = strpos($pair, '=');
    if ($eq === false) {
        fwrite(STDERR, "bad parameter: $pair\n");
        exit(64);
    }
    $params[substr($pair, 0, $eq)] = substr($pair, $eq + 1);
}
if ($bodyFile !== '-') {
    clearstatcache();
    $params['CONTENT_LENGTH'] = (string) filesize($bodyFile);
}

function fcgi_record($type, $content)
{
    return pack('CCnnCx', 1, $type, 1, strlen($content), 0) . $content;
}

function fcgi_length($len)
{
    return $len < 128 ? chr($len) : pack('N', $len | 0x80000000);
}

/* Returns false once the peer has gone away. */
function fcgi_write($sock, $data)
{
    while ($data !== '') {
        $n = @fwrite($sock, $data);
        if ($n === false || $n === 0) {
            return false;
        }
        $data = (string) substr($data, $n);
    }
    return true;
}

function fcgi_read($sock, $len)
{
    $buf = '';
    while (strlen($buf) < $len) {
        $chunk = @fread($sock, $len - strlen($buf));
        if ($chunk === false || $chunk === '') {
            if (feof($sock)) {
                return false;
            }
            $meta = stream_get_meta_data($sock);
            if ($meta['timed_out']) {
                return false;
            }
            continue;
        }
        $buf .= $chunk;
    }
    return $buf;
}

$sock = @stream_socket_client("tcp://$host:$port", $errno, $errstr, 5);
if (!$sock) {
    fwrite(STDERR, "connect failed: $errstr\n");
    exit(2);
}
stream_set_timeout($sock, 120);

/* BEGIN_REQUEST: role RESPONDER, no keep-alive */
$out = fcgi_record(1, pack('nCx5', 1, 0));
$pairs = '';
foreach ($params as $name => $value) {
    $pairs .= fcgi_length(strlen($name)) . fcgi_length(strlen($value)) . $name . $value;
}
foreach (str_split($pairs, 65535) as $chunk) {
    $out .= fcgi_record(4, $chunk);
}
$out .= fcgi_record(4, '');
$alive = fcgi_write($sock, $out);

if ($alive && $bodyFile !== '-') {
    $fh = fopen($bodyFile, 'rb');
    while ($alive && !feof($fh)) {
        $chunk = fread($fh, 65535);
        if ($chunk === false || $chunk === '') {
            break;
        }
        $alive = fcgi_write($sock, fcgi_record(5, $chunk));
    }
    fclose($fh);
}
if ($alive) {
    fcgi_write($sock, fcgi_record(5, ''));
}

$stdout = '';
$ended = false;
while (true) {
    $header = fcgi_read($sock, 8);
    if ($header === false) {
        break;
    }
    $h = unpack('Cversion/Ctype/nid/nlength/Cpadding', $header);
    $content = $h['length'] ? fcgi_read($sock, $h['length']) : '';
    if ($content === false || ($h['padding'] && fcgi_read($sock, $h['padding']) === false)) {
        break;
    }
    if ($h['type'] == 6) {
        $stdout .= $content;
    } elseif ($h['type'] == 7) {
        fwrite(STDERR, $content);
    } elseif ($h['type'] == 3) {
        $ended = true;
        break;
    }
}
fclose($sock);

$split = strpos($stdout, "\r\n\r\n");
echo $split === false ? $stdout : substr($stdout, $split + 4);
exit($ended ? 0 : 3);
