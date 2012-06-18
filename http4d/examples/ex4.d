/**
 * This example utilises the UriRouter class to dispatch
 * to a nominated handler based on the HTTP URI.
 * 
 * The default dispatch handler always returns a 404 if
 * the dispatcher fails to match the supplied criteria.
 */

import std.stdio, std.regex;
import protocol.http;

int main( string[] args )
{
    UriRouter dispatcher = new UriRouter;
    dispatcher.mount( "/abc$", &onABC );
    dispatcher.mount( "/def$", &onDEF );

    httpServe( "127.0.0.1:8888", (req) => dispatcher( req ) );
    return 0;
}

HttpResponse onABC( HttpRequest req )
{
     return req.getResponse().
             status( 200 ).
             header( "Content-Type", "text/plain" ).
             content( "Processed an ABC request" );
}

HttpResponse onDEF( HttpRequest req )
{
     return req.getResponse().
             status( 200 ).
             header( "Content-Type", "text/plain" ).
             content( "Processed a DEF request" );
}

