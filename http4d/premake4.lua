--require "d"
LuaD = "/data/devel-ext/LuaD"

solution "http4d"
    configurations { "debug", "release" }
    includedirs { "src", "src/cjson", "src/deimos", LuaD } 
    buildoptions "-Dddoc"
--    location "build"

    configuration "debug"
        flags { "Symbols", "ExtraWarnings" }

    configuration { "debug", "D" }
        buildoptions "-gc"

    configuration "release"
        flags { "Optimize" }

    configuration "test"
        buildoptions "-unittest"
        flags { "Symbols", "ExtraWarnings" }

    project "http4d"
        kind "ConsoleApp"
        language "D"
        files { "main.d", "src/protocol/*.d" }
        links { "zmq" }


    project "lsp"
        kind "ConsoleApp"
        language "D"
--        buildoptions "-v"
        files { "examples/luasp/lsp.d", "src/protocol/*.d", "src/luasp/*.d" }
        libdirs { LuaD .. "/lib" }
        links { "luad", "lua", "zmq", "dl" }
--[[
    project "ex1"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex1.d" }
        links { "http4d", "cJSON", "zmq" }

    project "ex2"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex2.d" }
        links { "http4d", "cJSON", "zmq" }

    project "ex3"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex3.d" }
        links { "http4d", "cJSON", "zmq" }

    project "ex4"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex4.d" }
        links { "http4d", "cJSON", "zmq" }
--]]

