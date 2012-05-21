
import std.stdio;
import protocol.http;

int main( string[] args )
{
    string addr = "0.0.0.0";
    ushort port = 8888;

    httpServe( "127.0.0.1", cast(ushort) 8888,
               ( HttpRequest req )
    {
        return handleRequest( req );
    } );

    return 0;
}

HttpResponse handleRequest( HttpRequest req )
{
    debug writeln( "Handling HTTP request for URI: " ~ req.uri );

    HttpResponse resp = req.getResponse();
    resp.statusCode = 200;
    resp.statusMesg = "OK";
    resp.addHeader( "Cache-Control", "public" );
    resp.data = cast( shared ubyte[] ) "<html><head></head><body><h1>Hi from HTTP-D!</h1></body></html>".dup;

    return resp;
}

