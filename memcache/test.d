
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

    //cleanup if last run wnet badly
    if( s.get( cast(ubyte[]) "abc" )[0].status == Status.OK )
        s.remove( cast(ubyte[]) "abc" );

    if( s.get( cast(ubyte[]) "abc2" )[0].status == Status.OK )
        s.remove( cast(ubyte[]) "abc2" );

    MemcacheObject obj;
    obj.key   = cast(ubyte[]) "abc";
    obj.value = cast(ubyte[]) "It's a quite nice thing";
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
    obj.cas = 0;
    assert( s.set( obj ).status == Status.OK );

    obj = s.getk( obj.key )[ 0 ];
//    assert( obj.key == ['a', 'b', 'c', '1' ] );

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

    s.incrq( cast(ubyte[]) "counter", 3, 0, 0xe10 );
    s.decrq( cast(ubyte[]) "counter", 6, 0, 0xe10 );

    writeln( "There are ", s.noop().length, " responses queued" );

    auto stats = s.stats();
    foreach( k, v; stats )
        writeln( "STATS: ", k, "\t", v );

    obj.key = cast(ubyte[]) "abc2";
    obj.cas = 0;
    obj.expiry = 1024;
    obj.value = cast(ubyte[]) "This is a changed value";
    dump( obj, "Reset obj for SETQ" );
    s.setq( obj );
    //after a SETQ, you must get the CAS value right if you want to do a REPLACE
    //AND ensure we use a GETK so that we have the original key in the field
    obj = s.getk( obj.key )[0];
    dump( obj, "Located obj via GETK" );
    writeln( "CAS = ", obj.cas );
    assert( obj.value == "This is a changed value" );
//    obj.value = cast(ubyte[]) "This is a changed value";
//    obj.expiry = 1024;
//    obj.cas = 0;
//    assert( s.replace( obj ).status == Status.OK );
    
//    obj = s.getk( obj.key )[0];
//    assert( obj.value == "This is a changed value" );

    s.append( obj.key, cast(ubyte[]) "_append1" );
    assert( s.get( obj.key )[0].value == "This is a changed value_append1" );
    s.appendq( obj.key, cast(ubyte[]) "_append2" );
    assert( s.get( obj.key )[0].value == "This is a changed value_append1_append2" );
    s.prepend( obj.key, cast(ubyte[]) "prepend1_" );
    assert( s.get( obj.key )[0].value == "prepend1_This is a changed value_append1_append2" );
    s.prependq( obj.key, cast(ubyte[]) "prepend2_" );
    assert( s.get( obj.key )[0].value == "prepend2_prepend1_This is a changed value_append1_append2" );

    s.removeq( obj.key );
    assert( s.get( obj.key )[0].status == Status.KEY_NOTFOUND );

    dump( s.set( obj ), "SET AGAIN" );
    s.getq( cast(ubyte[]) "abc1" );
    s.getq( cast(ubyte[]) "abc2" );
    s.getq( cast(ubyte[]) "abc3" );
    s.getq( cast(ubyte[]) "abc4" );
    s.getq( cast(ubyte[]) "abc5" );
    writeln( "noop() returned ", s.noop().length );

//    assert( s.remove( cast(ubyte[]) "counter" ) == Status.OK );
    s.flush( 86400 );
    s.flushq( 86400 );

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
