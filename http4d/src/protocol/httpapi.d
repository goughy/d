/**

HTTP4D provides an easy entry point for providing embedded HTTP support
into any D application.  The library provides endpoints for the following

Supported Protocols:
$(OL
    $(LI HTTP internal implementation)
    $(LI AJP internal implementation (incomplete))
    $(LI Mongrel2 - Relies on the ZMQ library))
It provides a very simple interface using request/response style making it very
easy to dispatch, route and handle a variety of web requests.

Example:
---
import std.stdio;
import protocol.http;

int main( string[] args )
{
    httpServe( "127.0.0.1", 8888,
                (req) => req.getResponse().
                            status( 200 ).
                            header( "Content-Type", "text/html" ).
                            content( "<html><head></head><body>Processed ok</body></html>" ) );
    return 0;
}
---
In general no attempt is made to ensure compliance to the HTTP protocol as part of the response
as that is deemed the responsibility of the developer using the library.  That is, this library
does not aim to be an HTTP/1.1 RFC 2616 compliant server, but rather an embeddable library
that can expose an endpoint that may be interacted with via an HTTP client
(such as a browser or programmatically eg. cURL).

This provides maximum flexibility to the developer, rather than implementing full server
constraints.  It is expected that an application would $(B $(I not)) expose itself to the
internet, but access would be moderated via a process with better security credentials, such
as $(LINK2 http://httpd.apache.org/, Apache), $(LINK2 http://www.nginx.org/, Nginx),
or $(LINK2 http://mongrel2.org/, Mongrel2).  The exception to this rule is with
respect to the "Connection" header, as that is used to determine the "keep-alive"
nature of the underlying socket connection - ie. set the "Connection" header to
"close" and the library will close the socket after transmitting the response.

However, by exposing an HTTP interface directly, those systems may proxy requests through
to a D application using this library incredibly easily.

License: $(LINK2 http://boost.org/LICENSE_1_0.txt, Boost License 1.0).

Authors: $(LINK2 https://github.com/goughy, Andrew Gough)

Source: $(LINK2 https://github.com/goughy/d/tree/master/http4d, github.com)
*/

module protocol.httpapi;
import std.stdio, std.array, std.regex, std.typecons, std.ascii, std.string, std.conv;
import std.concurrency;

// ------------------------------------------------------------------------- //

enum Method
{
    UNKNOWN,
    OPTIONS,
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    TRACE,
    CONNECT
};

// ------------------------------------------------------------------------- //

/**
 * The list of HTTP status codes from $(LINK2 http://en.wikipedia.org/wiki/List_of_HTTP_status_codes, Wikipedia)
 */
immutable string[ int ] StatusCodes;

static this()
{
    StatusCodes = [
                  100: "Continue",
                  101: "Switching Protocols",
                  102: "Processing",

                  200: "OK",
                  201: "Created",
                  202: "Accepted",
                  203: "Non-Authoritative Information",
                  204: "No Content",
                  205: "Reset Content",
                  206: "Partial Content",
                  207: "Multi-Status (RFC 4918)",
                  208: "Already Reported (RFC 5842)",
                  226: "IM Used (RFC 3229)",

                  300: "Mulitple Choices",
                  301: "Moved Permanently",
                  302: "Found",
                  303: "See Other",
                  304: "Not Modified",
                  305: "Use Proxy",
                  306: "Switch Proxy",
                  307: "Temporary Redirect",
                  308: "Permanent Redirect",

                  400: "Bad Request",
                  401: "Unauthorized",
                  402: "Payment Required",
                  403: "Forbidden",
                  404: "Not Found",
                  405: "Method Not Allowed",
                  406: "Not Acceptable",
                  407: "Proxy Authentication Required",
                  408: "Request Timeout",
                  409: "Conflict",
                  410: "Gone",
                  411: "Length Required",
                  412: "Precondition Failed",
                  413: "Request Entity Too Large",
                  414: "Request-URI Too Long",
                  415: "Unsupported Media Type",
                  416: "Requested Range Not Satisfiable",
                  417: "Expectation Failed",
                  418: "I'm a teapot (RFC 2324)", //wtf!
                  420: "Enhance Your Calm (Twitter)",
                  422: "Unprocessable Entity (RFC 4918)",
                  423: "Locked (RFC 4918)",
                  424: "Failed Dependency (RFC 4918)",
                  425: "Unordered Collection (RFC 3648)",
                  426: "Upgrade Required (RFC 2817)",
                  428: "Precondition Required",
                  429: "Too Many Requests",
                  431: "Request Header Fields Too Large",
                  444: "No Response (Nginx)",
                  449: "Retry With (Microsoft)", //M$ extension
                  450: "Blocked By Windows Parental Controls (Microsoft)",
                  499: "Client Closed Request (Nginx)",

                  500: "Internal Server Error",
                  501: "Not Implemented",
                  502: "Bad Gateway",
                  503: "Service Unavailable",
                  504: "Gateway Timeout",
                  505: "HTTP Version Not Supported",
                  506: "variant Also Negotiates (RFC 2295)",
                  507: "Insufficient Storage (RFC 4918)",
                  508: "Loop Detected (RFC 5842)",
                  509: "Bandwidth Limit Exceeded (Apache)",
                  510: "Not Extended (RFC 2774)",
                  511: "Network Authenticated Required",
                  598: "Network read timeout error",
                  599: "Network connect timeout error"
                  ];
}

// ------------------------------------------------------------------------- //

/**
 * The $(D Request) class encapsulates all captured data from the inbound client
 * request.  It is the core class the library provides to model an HTTP request
 * from any source.
 *
 * Note that this class is defined as shared to support the asynchronous dispatch
 * model using std.concurrency.
 */

shared class Request
{
public:

    this( string id = "" )
    {
        connection = id;
    }
    
    Tid             tid;
    string          connection;
    Method          method;
    string          protocol;
    string          uri;
    string[string]  headers;
    string[string]  attrs;
    ubyte[]         data;

    string getHeader( string k )
    {
        return headers[ capHeader( k.dup ) ];
    }

    string getAttr( string k )
    {
        return attrs[ k.toLower ];
    }

    shared( Response ) getResponse()
    {
        //bind the response to the reqest connection
        shared Response resp = cast( shared ) new Response( connection, protocol );

        if( "Connection" in headers )
            resp.addHeader( "Connection", getHeader( "Connection" ) );

        return resp;
    }
}

// ------------------------------------------------------------------------- //

/**
 * The $(D_PSYMBOL Response) class is delivered back to the library to be serialized and
 * transmitted to the underlying socket as defined by the $(D_PARAM connection)
 * parameter.  In general, the $(D_PARAM getResponse()) function on the
 * $(D_PSYMBOL Request) should be used to create the $(D_PSYMBOL Response) as this ensures the
 * $(D_PARAM connection) attribute is copied from the request.  However, this is
 * not strictly necessary, and a Response may be created manually so long as the
 * $(D_PARAM Request.connection) is copied to the $(D_PARAM Response.connection).
 *
 * Note that this class is defined as shared to support the asynchronous dispatch
 * model using std.concurrency.
 */

shared class Response
{
public:

    this( string id = "", string proto  = "" )
    {
        connection = id;
        protocol = proto;
    }

    string          connection;
    string          protocol;
    int             statusCode;
    string          statusMesg;
    string[string]  headers;
    ubyte[]         data;

    shared( Response ) addHeader( string k, string v )
    {
        headers[ capHeader( k.dup ) ] = v;
        return this;
    }
}

// ------------------------------------------------------------------------- //
/**
 * The function protoype for the predefined dispatchers.  Any defined handler function
 * must implement this signature.
 *
 * Example:
 * ---
 *
 * import std.stdio;
 * import protocol.http;
 *
 * int main( string[] args )
 * {
 *     httpServe( "127.0.0.1", 8888, (req) => handleReq( req ) );
 *     return 0;
 * }
 *
 * shared(Response) handleReq( shared(Request) req )
 * {
 *      return req.getResponse().
 *              status( 200 ).
 *              header( "Content-Type", "text/html" ).
 *              content( "<html><head></head><body>Processed ok</body></html>" );
 * }
 * ---
 */
alias shared( Response ) function( shared( Request ) ) RequestHandler;

alias shared( Request ) HttpRequest;
alias shared( Response ) HttpResponse;

// ------------------------------------------------------------------------- //

/**
 * Dispatcher base class for setting the default handler and providing
 * $(D_PSYMBOL opCall()).  DO NOT USE! Use one of the subclasses instead (or
 * subclass your own)
 */

class Dispatch
{
public:

    this()
    {
        defHandler = ( req ) => error( req.getResponse(), 404 );
    }

    RequestHandler defaultHandler( RequestHandler func )
    {
        auto old = defHandler;
        defHandler = func;
        return old;
    }

    HttpResponse opCall( HttpRequest r )
    {
        return dispatch( r );
    }

    HttpResponse dispatch( HttpRequest req )
    {
        return defHandler( req );
    }

protected:

    RequestHandler defHandler;
}

// ------------------------------------------------------------------------- //

/**
 * A convenience class that provides a dispatch mecahnism based on the
 * HTTP Method in a $(D_PSYMBOL Request).
 *
 * Example:
 * ---
 * import std.stdio;
 * import protocol.http;
 *
 * int main( string[] args )
 * {
 *     MethodDispatch dispatcher = new MethodDispatch;
 *     dispatcher.mount( Method.GET, &onGet );
 *     dispatcher.mount( Method.POST, &onPost );
 *
 *     httpServe( "127.0.0.1", 8888, (req) => dispatcher( req ) );
 *     return 0;
 * }
 *
 * shared(Response) onGet( shared(Request) req )
 * {
 *      return req.getResponse().
 *              status( 200 ).
 *              header( "Content-Type", "text/html" ).
 *              content( "<html><head></head><body>Processed ok</body></html>" );
 * }
 *
 * shared(Response) onPost( shared(Request) req )
 * {
 *     return req.getResponse().error( 405 );
 * }
 * ---
 */

class MethodDispatch : Dispatch
{
public:

    void mount( Method m, RequestHandler func )
    {
        HandlerType ht;
        ht.m = m;
        ht.f = func;
        handlerMap ~= ht;
    }

    override HttpResponse dispatch( HttpRequest req )
    {
        foreach( handler; handlerMap )
        {
            if( req.method == handler.m )
                return handler.f( req );
        }
        return defHandler( req );
    }

private:

    alias Tuple!( Method, "m", RequestHandler, "f" ) HandlerType;
    HandlerType[]  handlerMap;
}

// ------------------------------------------------------------------------- //
/**
 * A convenience class that provides a dispatch mechanism based on the
 * URI in a $(D_PSYMBOL Request) using regular expressions.
 *
 * Example:
 * ---
 * import std.stdio, std.regex;
 * import protocol.http;
 *
 * int main( string[] args )
 * {
 *     UriDispatch dispatcher = new UriDispatch;
 *     dispatcher.mount( regex( "/abc$" ), &onABC );
 *     dispatcher.mount( regex( "/def$" ), &onDEF );
 *
 *     httpServe( "127.0.0.1", 8888, (req) => dispatcher( req ) );
 *     return 0;
 * }
 *
 * shared(Response) onABC( shared(Request) req )
 * {
 *      return req.getResponse().
 *              status( 200 ).
 *              header( "Content-Type", "text/plain" ).
 *              content( "Processed an ABC request" );
 * }
 *
 * shared(Response) onDEF( shared(Request) req )
 * {
 *      return req.getResponse().
 *              status( 200 ).
 *              header( "Content-Type", "text/plain" ).
 *              content( "Processed a DEF request" );
 * }
 * ---
 */

class UriDispatch : Dispatch
{
public:

    void mount( Regex!char regex, RequestHandler func )
    {
        HandlerType ht;
        ht.r = regex;
        ht.f  = func;
        handlerMap ~= ht;
    }

    override HttpResponse dispatch( HttpRequest req )
    {
        foreach( handler; handlerMap )
        {
            if( match( req.uri, handler.r ) )
                return handler.f( req );
        }
        return defHandler( req );
    }

private:

    alias Tuple!( Regex!char, "r", RequestHandler, "f" ) HandlerType;
    HandlerType[] handlerMap;
}

// ------------------------------------------------------------------------- //

Method toMethod( string m )
{
    //enum Method { UNKNOWN, OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE, CONNECT };
    switch( m.toLower() )
    {
        case "get":
            return Method.GET;

        case "post":
            return Method.POST;

        case "head":
            return Method.HEAD;

        case "options":
            return Method.OPTIONS;

        case "put":
            return Method.PUT;

        case "delete":
            return Method.DELETE;

        case "trace":
            return Method.TRACE;

        case "connect":
            return Method.CONNECT;

        default:
            break;
    }

    return Method.UNKNOWN;
}

// ------------------------------------------------------------------------- //

/**
 * Parse an address of the form "x.x.x.x:yyyy" into a string address and 
 * corresponding ushort port
 */
Tuple!(string,ushort) parseAddr( string addr )
{
    auto res = std.algorithm.findSplit( addr, ":" );
    ushort port = (res.length == 3) ? to!ushort( res[ 2 ] ) : 8080; //default to 8080

    return tuple( res[ 0 ], port );
}

// ------------------------------------------------------------------------- //

string capHeader( char[] hdr )
{
    bool up = true; //uppercase first letter
    foreach( i, char c; hdr )
    {
        if( isAlpha( c ) )
        {
            hdr[ i ] = cast( char )( up ? toUpper( c ) : toLower( c ) );
            up = false;
        }
        else
            up = true;
    }
    return hdr.idup;
}

// ------------------------------------------------------------------------- //

/** Convenience function to set the HTTP response status code and message */
HttpResponse status( HttpResponse r, int c, string m = null )
{
    r.statusCode = c;
    r.statusMesg = m;

    if( m is null )
        r.statusMesg = c in StatusCodes ? StatusCodes[ c ] : "";

    return r;
}

/** Convenience function to set the HTTP response status code and message to '200 OK'*/
shared( Response ) ok( shared( Response ) r )                           { return status( r, 200 ); }
/** Convenience function to set the HTTP response status code */
shared( Response ) error( shared( Response ) r, int c )                 { return status( r, c ); }
/** Convenience function to set the HTTP response status code */
shared( Response ) notfound( shared( Response ) r )                     { return status( r, 404 ); }

/** Convenience function to set the HTTP response status message */
shared( Response ) msg( shared( Response ) r, string m )                { r.statusMesg = m; return r; }
/** Convenience function to set a $(D_PSYMBOL Response) header */
shared( Response ) header( shared( Response ) r, string h, string v )   { r.headers[ h ] = v; return r; }
/** Convenience function to set a $(D_PSYMBOL Response) content */
shared( Response ) content( shared( Response ) r, string v )            { r.data = cast( shared ubyte[] ) v.dup; return r; }
/** Convenience function to set a $(D_PSYMBOL Response) content */
shared( Response ) content( shared( Response ) r, char[] v )            { r.data = cast( shared ubyte[] ) v; return r; }
/** Convenience function to set a $(D_PSYMBOL Response) content */
shared( Response ) content( shared( Response ) r, ubyte[] v )           { r.data = cast( shared ubyte[] ) v; return r; }

// ------------------------------------------------------------------------- //

debug void dump( shared( Request ) r, string title = "" )
{
    if( title.length > 0 )
        writeln( title );

    writeln( "Connection: ", r.connection.idup );
    writeln( "Method    : ", r.method );
    writeln( "Protocol  : ", r.protocol.idup );
    writeln( "URI       : ", r.uri.idup );

    foreach( k, v; r.headers )
    writeln( "\t", k.idup, ": ", v.idup );

    foreach( k, v; r.attrs )
    writeln( "\t", k.idup, ": ", v.idup );
}

// ------------------------------------------------------------------------- //

debug void dump( shared( Response ) r, string title = "" )
{
    if( title.length > 0 )
        writeln( title );

    writeln( "Connection: ", r.connection.idup );
    writeln( "Status    : ", r.statusCode, " ", r.statusMesg.idup );

    foreach( k, v; r.headers )
    writeln( "\t", k.idup, ": ", v.idup );

    dumpHex( cast( char[] ) r.data );
}

// ------------------------------------------------------------------------- //


debug void dumpHex( char[] buf, string title = "", int cols = 16 )
{
    assert( cols < 256 );

    if( title.length > 0 )
        writeln( title );

    char[ 256 ] b1;
    int x = 0, i = 0;

    for( ; i < buf.length; ++i )
    {
        if( x > 0 && i > 0 && i % cols == 0 )
        {
            writefln( "   %s", b1[ 0 .. x ] );
            x = 0;
        }

        b1[ x++ ] = .isPrintable( buf[ i ] ) ? buf[ i ] : '.';
        writef( "%02x ", buf[ i ] );
    }

//      writefln( "\n(D) x = %d, i = %d", x, i );
    if( x > 0 )
        writefln( "%s   %s", ( cols > x ) ? replicate( "   ", cols - x ) : "", b1[ 0 .. x ] );
}

// ------------------------------------------------------------------------- //


