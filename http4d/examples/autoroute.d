
import std.stdio;
import protocol.http;

class Account
{
public:

    HttpResponse getAccount( HttpRequest req )
    {
        return req.getResponse().ok().content( "<html><head></head><body><h1>GET account</h1><br />" ~ req.uri ~ "</body></html>" );
    }

    HttpResponse getAccounts( HttpRequest req )
    {
        return req.getResponse().ok().content( "<html><head></head><body><h1>GET account list</h1><br />" ~ req.uri ~ "</body></html>" );
    }

    HttpResponse postAccount( HttpRequest req )
    {
        return req.getResponse().ok().content( "<html><head></head><body><h1>POST account</h1><br />" ~ req.uri ~ "</body></html>" );
    }

    HttpResponse getTest( HttpRequest req )
    {
        debug dump( req );
        return req.getResponse().ok().content( "<html><head></head><body><h1>GET test</h1><br />" ~ req.uri ~ "</body></html>" );
    }
}

class NoRoutes
{
    HttpResponse unknownMethod( HttpRequest req )
    {
        return req.getResponse().error( 404 );
    }

    int postSomeFailed( HttpRequest req )
    {
        return 0;
    }

    HttpResponse getSomeOtherMethod( int i )
    {
        return null;
    }
}

int main( string[] args )
{
    auto oops = new AutoRouter!NoRoutes;
    oops.dumpRoutes();

    auto router = new AutoRouter!Account( "/v1" );
    router.dumpRoutes();
    httpServe( "0.0.0.0:8000", (req) => router( req ) );
    return 0;
}
