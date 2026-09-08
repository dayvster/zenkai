api.log("ZENKAI TEST: FILE LOADED")

function on_query(query)
	api.log("ZENKAI TEST: on_query called: " .. tostring(query))

	local id = api.add_result("TEST ZENKAI", "test", "utilities-terminal", "ExecCmd")

	api.log("ZENKAI TEST: result id = " .. tostring(id))
end

function on_open(id)
	api.log("ZENKAI TEST: on_open called: " .. tostring(id))

	os.execute('notify-send "ZENKAI TEST WORKS"')
end
