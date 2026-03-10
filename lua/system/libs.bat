@echo off

rem Install scoop package manager
call "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser"
call "Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression"

call "scoop bucket add main"
call "scoop install main/luarocks"


rem Libs
call "luarocks install --local json-lua"
call "luarocks install --local ldoc"
call "luarocks install --local dkjson"
