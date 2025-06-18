@echo off
setlocal EnableDelayedExpansion

set "HTA_FILE=%TEMP%\user_form.hta"
set "RESULT_FILE=%TEMP%\form_result.txt"
if exist "%RESULT_FILE%" del "%RESULT_FILE%"

> "%HTA_FILE%" echo ^<html^>
>> "%HTA_FILE%" echo ^<head^>
>> "%HTA_FILE%" echo ^<meta charset="utf-8"^>
>> "%HTA_FILE%" echo ^<title^>Форма ввода^</title^>
>> "%HTA_FILE%" echo ^<style^>
>> "%HTA_FILE%" echo body {
>> "%HTA_FILE%" echo   font-family: Segoe UI, sans-serif;
>> "%HTA_FILE%" echo   background-color: #f0f4f8;
>> "%HTA_FILE%" echo   padding: 20px;
>> "%HTA_FILE%" echo   width: 280px;
>> "%HTA_FILE%" echo   margin: auto;
>> "%HTA_FILE%" echo }
>> "%HTA_FILE%" echo h3 {
>> "%HTA_FILE%" echo   color: #0078d7;
>> "%HTA_FILE%" echo   text-align: center;
>> "%HTA_FILE%" echo   margin-bottom: 12px;
>> "%HTA_FILE%" echo }
>> "%HTA_FILE%" echo .myinput {
>> "%HTA_FILE%" echo   width: 100%%;
>> "%HTA_FILE%" echo   padding: 8px;
>> "%HTA_FILE%" echo   font-size: 14px;
>> "%HTA_FILE%" echo   margin-top: 8px;
>> "%HTA_FILE%" echo   border-radius: 4px;
>> "%HTA_FILE%" echo   border: 1px solid #ccc;
>> "%HTA_FILE%" echo   box-sizing: border-box;
>> "%HTA_FILE%" echo }
>> "%HTA_FILE%" echo input[type=button] {
>> "%HTA_FILE%" echo   width: 100%%;
>> "%HTA_FILE%" echo   background: linear-gradient(#3399ff, #0078d7);
>> "%HTA_FILE%" echo   color: white;
>> "%HTA_FILE%" echo   border: none;
>> "%HTA_FILE%" echo   padding: 10px;
>> "%HTA_FILE%" echo   font-size: 14px;
>> "%HTA_FILE%" echo   margin-top: 12px;
>> "%HTA_FILE%" echo   border-radius: 4px;
>> "%HTA_FILE%" echo   cursor: pointer;
>> "%HTA_FILE%" echo   transition: background 0.3s;
>> "%HTA_FILE%" echo }
>> "%HTA_FILE%" echo input[type=button]:hover {
>> "%HTA_FILE%" echo   background: linear-gradient(#0078d7, #005a9e);
>> "%HTA_FILE%" echo }
>> "%HTA_FILE%" echo ^</style^>
>> "%HTA_FILE%" echo ^</head^>
>> "%HTA_FILE%" echo ^<body^>
>> "%HTA_FILE%" echo ^<HTA:APPLICATION ID="UserForm" APPLICATIONNAME="Form" BORDER="thin" SCROLL="no" SINGLEINSTANCE="yes" WINDOWSTATE="normal" /^>
>> "%HTA_FILE%" echo ^<h3^>Введите имя:^</h3^>
>> "%HTA_FILE%" echo ^<input type="text" id="username" class="myinput" placeholder="Иван Иванов"^>
>> "%HTA_FILE%" echo ^<input type="button" value="Отправить" onclick="SubmitForm()"^>
>> "%HTA_FILE%" echo ^<script language="VBScript"^>
>> "%HTA_FILE%" echo Sub SubmitForm()
>> "%HTA_FILE%" echo     Dim fso, file
>> "%HTA_FILE%" echo     Set fso = CreateObject("Scripting.FileSystemObject")
>> "%HTA_FILE%" echo     Set file = fso.CreateTextFile("%RESULT_FILE%", True)
>> "%HTA_FILE%" echo     file.WriteLine document.getElementById("username").value
>> "%HTA_FILE%" echo     file.Close
>> "%HTA_FILE%" echo     window.close
>> "%HTA_FILE%" echo End Sub
>> "%HTA_FILE%" echo ^</script^>
>> "%HTA_FILE%" echo ^</body^>
>> "%HTA_FILE%" echo ^</html^>

:: Запуск формы
start /wait mshta.exe "%HTA_FILE%"

:: Ожидание результата
:waitloop
if not exist "%RESULT_FILE%" (
    timeout /t 1 >nul
    goto waitloop
)

:: Чтение
set /p USERNAME=<"%RESULT_FILE%"
echo [INFO] Введено: %USERNAME%

pause
del "%HTA_FILE%" >nul 2>&1
del "%RESULT_FILE%" >nul 2>&1
