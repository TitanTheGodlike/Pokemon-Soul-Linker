@echo off
rem Builds "Soul Link.exe" (in the folder above) from the .cs files here, with the C# compiler
rem that comes with Windows' .NET Framework 4 - nothing to install.
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
"%CSC%" /nologo /optimize+ /target:winexe "/out:%~dp0..\Soul Link.exe" "/win32icon:%~dp0soullink.ico" ^
  /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll ^
  /reference:Microsoft.CSharp.dll /reference:System.Core.dll ^
  "%~dp0Program.cs" "%~dp0Link.cs" "%~dp0Launcher.cs" "%~dp0Window.cs"
