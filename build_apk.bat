@echo off
set JAVA_HOME=C:\JDK\jdk-17.0.2
set ANDROID_HOME=C:\Android\Sdk
set Path=C:\Program Files\Git\bin;C:\flutter\bin;C:\JDK\jdk-17.0.2\bin;%Path%
cd /d C:\FamilyMap
echo JAVA_HOME is: %JAVA_HOME%
echo Checking java.exe...
if exist "%JAVA_HOME%\bin\java.exe" (
    echo java.exe found
) else (
    echo java.exe NOT found
)
echo Starting build...
call flutter build apk --debug
