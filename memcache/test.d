
import memcache;
import std.stdio, std.conv, std.datetime, std.concurrency;


void threadFunc( string prefix, int num )
{
    StopWatch sw;
    MemcacheServer s = new MemcacheServer();
    sw.start();
    for( int i = 0; i < num; ++i )
    {
        MemcacheObject o;
        o.key   = cast(ubyte[]) ("key_" ~ prefix ~ to!string( i )).dup;
        o.value = cast(ubyte[]) std.array.replicate( "a", 47 ).dup;
        
        s.set( o );
    }
    writeln( prefix, ": 100 objects in ", sw.peek().msecs );
}

int main( string[] args )
{
    MemcacheServer s = new MemcacheServer();

    writeln( "Connected to server version: ", s.versionStr() );

    MemcacheObject obj;
    obj.key   = cast(ubyte[]) "abc";
    obj.value = cast(ubyte[]) "It's is a quite nice thing";
    obj.flags = 0xdeadbeef;
    obj.expiry = 0xe10;

    MemcacheObject[] objects = s.get( cast(ubyte[]) "abc" );
    if( objects.length == 1 && objects[ 0 ].status == Status.KEY_NOTFOUND )
    {
        writeln( "Key 'abc' not found - adding" );
        assert( s.add( obj ).status == Status.OK );
        writeln( "Added CAS = ", obj.cas );

        objects = s.get( obj.key );
        assert( objects[ 0 ].flags == 0xdeadbeef );
    }

    foreach( o; objects )
        dump( o );

    assert( s.remove( obj.key ) == Status.OK );

    obj.key = cast(ubyte[]) "abc1";
    assert( s.set( obj ).status == Status.OK );

    obj = s.getk( obj.key )[ 0 ];
    assert( obj.key == ['a', 'b', 'c', '1' ] );

    assert( s.remove( obj.key ) == Status.OK );
    
    try
    {
        s.incr( cast(ubyte[]) "counter", 3 );
    }
    catch( MemcacheException me ) 
    {
        writeln( "Counter 'counter' expected failure ok, try with a real expiry" );
    }
    writeln( "Counter 'counter' INCR: ", s.incr( cast(ubyte[]) "counter", 3, 0, 0xe10 ) );
    writeln( "Counter 'counter' DECR: ", s.decr( cast(ubyte[]) "counter", 6, 0, 0xe10 ) );

    writeln( "There are ", s.noop().length, " responses queued" );

    auto stats = s.stats();
    foreach( k, v; stats )
        writeln( "STATS: ", k, "\t", v );

    assert( s.set( obj ).status == Status.OK );
    s.getq( cast(ubyte[]) "abc1" );
    s.getq( cast(ubyte[]) "abc2" );
    s.getq( cast(ubyte[]) "abc3" );
    s.getq( cast(ubyte[]) "abc4" );
    s.getq( cast(ubyte[]) "abc5" );
    writeln( "noop() returned ", s.noop().length );
    assert( s.remove( obj.key ) == Status.OK );

    s.quit();

//    MemcacheServer[] servers;
//    servers.length = 100;
//    for( int i = 0; i < 100; ++i )
//    {
//        spawn( &threadFunc, to!string( i ), 100 );
//    }
//

    return 0;
}
