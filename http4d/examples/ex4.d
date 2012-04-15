/**
 * This example utilises the UriDispatch class to dispatch
 * to a nominated handler based on the HTTP URI.
 * 
 * The default dispatch handler always returns a 404 if
 * the dispatcher fails to match the supplied criteria.
 */

import std.stdio, std.regex;
import protocol.http;

int main( string[] args )
{
    UriDispatch dispatcher = new UriDispatch;
    dispatcher.mount( regex( "/abc$" ), &onABC );
    dispatcher.mount( regex( "/def$" ), &onDEF );

    httpServe( "127.0.0.1", 8888, (req) => dispatcher( req ) );
    return 0;
}

shared(Response) onABC( shared(Request) req )
{
     return req.getResponse().
             status( 200 ).
             header( "Content-Type", "text/plain" ).
             content( "Processed an ABC request" );
}

shared(Response) onDEF( shared(Request) req )
{
     return req.getResponse().
             status( 200 ).
             header( "Content-Type", "text/plain" ).
             content( "Processed a DEF request" );
}

