
module protocol.httpapi;
import std.regex, std.typecons, std.ascii, std.string;

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
 * See https://en.wikipedia.org/wiki/List_of_HTTP_status_codes
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
        207: "Multi-Status",
        208: "Already Reported",
        226: "IM Used",

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
        418: "I'm a teapot", //wtf!
        420: "Enhance Your Calm",
        422: "Unprocessable Entity",
        423: "Locked",
        424: "Failed Dependency",
        425: "Unordered Collection",
        426: "Upgrade Required",
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
        506: "variant Also Negotiates",
        507: "Insufficient Storage",
        508: "Loop Detected",
        509: "Bandwidth Limit Exceeded",
        510: "Not Extended",
        511: "Network Authenticated Required",
        598: "Network read timeout error",
        599: "Network connect timeout error"
    ];
}

// ------------------------------------------------------------------------- //

shared class Request
{
public:

    this( string id = "" )
    {
        connection = id;
    }

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

    shared(Response) getResponse()
    { 
        //bind the response to the reqest connection
        shared Response resp = cast(shared) new Response( connection, protocol );
        if( "Connection" in headers )
            resp.addHeader( "Connection", getHeader( "Connection" ) );

        return resp;
    }
}

// ------------------------------------------------------------------------- //

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

    shared(Response) addHeader( string k, string v )
    {
        headers[ capHeader( k.dup ) ] = v;
        return this;
    }
}

// ------------------------------------------------------------------------- //

alias shared(Response) function( shared(Request) ) RequestHandler;

// ------------------------------------------------------------------------- //

class Dispatch
{
public:

    this()
    {
        defHandler = (req) => req.getResponse().error( 404 );
    }

    RequestHandler defaultHandler( RequestHandler func )
    {
        auto old = defHandler;
        defHandler = func;
        return old;
    }

    shared(Response) opCall( shared(Request) r )
    {
        return dispatch( r );
    }

    shared(Response) dispatch( shared(Request) req )
    {
        return defHandler( req );
    }

protected:

    RequestHandler defHandler;
}

// ------------------------------------------------------------------------- //

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

    override shared(Response) dispatch( shared(Request) req )
    {
        foreach( handler; handlerMap )
        {
            if( req.method == handler.m )
                return handler.f( req );
        }
        return defHandler( req );
    }

private:

    alias Tuple!(Method, "m", RequestHandler, "f" ) HandlerType;
    HandlerType[]  handlerMap;
}

// ------------------------------------------------------------------------- //

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

    override shared(Response) dispatch( shared(Request) req )
    {
        foreach( handler; handlerMap )
        {
            if( match( req.uri, handler.r ) )
                return handler.f( req );
        }
        return defHandler( req );
    }

private:

    alias Tuple!(Regex!char, "r", RequestHandler, "f" ) HandlerType;
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

string capHeader( char[] hdr )
{
    bool up = true; //uppercase first letter
    foreach( i, char c; hdr ) 
    {
        if( isAlpha( c ) )
        {
            hdr[ i ] = cast(char)(up ? toUpper( c ) : toLower( c ));
            up = false;
        }
        else
            up = true;
    }
    return hdr.idup;
}

// ------------------------------------------------------------------------- //

shared(Response) status( shared(Response) r, int c, string m = null )
{
    r.statusCode = c;
    r.statusMesg = m;
    if( m is null )
        r.statusMesg = c in StatusCodes ? StatusCodes[ c ] : "";

    return r;
}

shared(Response) ok( shared(Response) r )                           { return r.status( 200 ); }
shared(Response) error( shared(Response) r, int c )                 { return r.status( c ); }
shared(Response) notfound( shared(Response) r )                     { return r.status( 404 ); }

shared(Response) msg( shared(Response) r, string m )                { r.statusMesg = m; return r; }
shared(Response) header( shared(Response) r, string h, string v )   { r.headers[ h ] = v; return r; }
shared(Response) content( shared(Response) r, string v )            { r.data = cast(shared ubyte[]) v.dup; return r; }
shared(Response) content( shared(Response) r, char[] v )            { r.data = cast(shared ubyte[]) v; return r; }
shared(Response) content( shared(Response) r, ubyte[] v )           { r.data = cast(shared ubyte[]) v; return r; }
