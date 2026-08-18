/// Messages for the ways a call to the trusted service can fail to happen at
/// all.
///
/// Six services each spoke to the server and each wrote the same three
/// sentences by hand. That was survivable while the sentences were right; it
/// stopped being survivable when one of them turned out to be wrong in the same
/// way six times.
library;

import 'package:flutter/foundation.dart' show kIsWeb;

/// What to say when the request never reached the server.
///
/// `http.ClientException` means different things on different platforms, and the
/// services were reporting only one of them.
///
/// On mobile it really is the network. On **web** it is most often CORS: the
/// browser refused the request because the response carried no
/// `Access-Control-Allow-Origin` for this page's origin. Every one of these
/// services already logged "on web, check CORS" to the debug console — and then
/// told the user to check their connection.
///
/// That cost real time: registering a bin from a local build served on a port
/// missing from the server's `ALLOWED_ORIGINS` produced "check your connection"
/// while the server was up and answering `/health` in 300 ms.
///
/// So the web wording names both possibilities without jargon. It has to stay
/// true in production, where a signed-in administrator on the hosted origin sees
/// this only if the service is genuinely down.
String get unreachableServerMessage => kIsWeb
    ? 'Could not reach the server. It may be offline, or it may be refusing '
        'requests from this address.'
    : 'Could not reach the server. Check your connection.';

/// What to say when the server was reached but took too long.
///
/// Render's free instance sleeps after about 15 minutes idle and takes 30–60
/// seconds to wake, so the first action after a quiet period can time out
/// through no fault of the user or the network.
const String slowServerMessage =
    'The server took too long to respond. It may be starting up — try again in '
    'a moment.';
