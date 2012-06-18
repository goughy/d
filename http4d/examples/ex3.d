/**
 * This example utilises the MethodRouter class to dispatch
 * to a nominated handler based on the HTTP method type.
 * 
 * Note that the Router class provides a 'defaultHandler()'
 * function that enables the provision of a default handler 
 * should any registered handler fail to match the criteria
 */

import std.stdio;
import protocol.http;

RequestHandler oldDefault;

int main( string[] args )
{
    MethodRouter dispatcher = new MethodRouter;
    dispatcher.mount( Method.GET, &onGet );
    dispatcher.mount( Method.POST, &onPost );
 
    oldDefault = dispatcher.defaultHandler( &onDefault ); //specify your own default

    httpServe( "127.0.0.1:8888", (req) => dispatcher( req ) );
    return 0;
}

HttpResponse onGet( HttpRequest req )
{
     return req.getResponse().
             status( 200 ).
             header( "Content-Type", "text/html" ).
             content( "<html><head></head><body>Processed GET request ok</body></html>" );
}

HttpResponse onPost( HttpRequest req )
{
    debug dump( req, "POST request contents" );
    return req.getResponse().error( 405 );
}

HttpResponse onDefault( HttpRequest req )
{
    if( req.method == Method.GET )
        return req.getResponse().ok().
                 header( "Content-Type", "text/html" ).
                 content( "<html><head></head><body>Looks like there is nothing here - maybe you should...</body></html>" );

    return oldDefault( req );
}

