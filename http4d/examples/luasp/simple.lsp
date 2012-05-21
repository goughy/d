<?# This is comment ?>

<html>
<head><title>Hello from luasp</title></head>

<body>

Session: <?=env.session?><br>
Filename: <?=env.filename?><br>

<?print('Your IP address: '..env.remote_ip)?><br>

METHOD: <?=env.method?><br>
URI: <?=env.uri?><br>
ARGS: <?=env.args?><br>
UUID: <?=uuid_gen()?><br>



<?
    echo( "Type of args = " .. type( args ) )
    echo( "<br>" )
    echo( "Type of args_decode = " .. type( args_decode ) )
    echo( "<br>" )
    echo( "Type of args_decode( args ) = " .. type( args_decode( args ) ) )
    echo( "<br>" )

    for k,v in pairs( args_decode( args ) ) do
        echo( "<br>&gt;&gt; " .. k .. " = " .. v )
    end

?>
<p>dynamic testing works - again
<?
log( "Finalising Lua Page" )
?>

</body>

</html>

