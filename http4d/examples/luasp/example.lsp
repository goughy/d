<?
-- call 'content_type' and 'set_out_header' before starting output

-- optional, default - text/html
    content_type('text/html')

    set_out_header('X-LSP','Welcome')
    
    if not mutex then mutex=0 end
?>

<?# This is comment ?>

<html>
<head><title>Hello from luasp</title></head>

<body>

This is <?if mutex==0 then?>first<?else?>second<?end?> request<br>

Mutex value: <?=mutex?><br><br>

Session: <?=env.session?><br>
Your IP address: <?=env.remote_ip?><br>
URI: <?=env.uri?><br><br>

<?
    print('Arguments from request line:<br>')
    for i,j in pairs(args_decode(env.args)) do
	    print(i..'='..j..'<br>')
    end
?>

<br>

<?
--    curl.timeout(5)

--    req=curl.open('GET','http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt')

--    content=req:send()

--    if req:status()==200 then
--	echo('<pre>')
--	print(content)
--	echo('</pre>')
--    end
    
    content=nil			-- optional, this free the memory
?>
	

<br><br>
<a href='<?=env.uri?>?param1=value+1&param2=value+2&mutex=<?=mutex?>'>reload</a>

</body>

</html>

<?mutex=mutex+1?>

