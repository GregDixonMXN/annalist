#!/usr/bin/env python3
"""Linux controlling-PTY regressions; synthetic HOME/XDG only."""
import os,pathlib,pty,select,signal,subprocess,sys,tempfile,time
binary=str(pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/annalist').resolve())
for interrupt in (False,True):
    with tempfile.TemporaryDirectory(prefix='annalist-pty-') as tmp:
        env=dict(os.environ,HOME=tmp+'/home',XDG_DATA_HOME=tmp+'/data')
        subprocess.run([binary,'init'],cwd=tmp,env=env,check=True,capture_output=True)
        pid,fd=pty.fork()
        if pid==0:
            os.chdir(tmp)
            command='printf "READY\\n"; read answer; printf "%s" "$answer" > answer.txt'
            result=subprocess.run([binary,'run','--','sh','-c',command],env=env)
            restored=os.tcgetpgrp(0)==os.getpgrp()
            pathlib.Path(tmp,'restored').write_text(str(restored))
            os._exit(0 if restored and result.returncode==(130 if interrupt else 0) else 1)
        data=b'';status=None
        try:
            deadline=time.monotonic()+12;sent=False
            while time.monotonic()<deadline:
                if select.select([fd],[],[],.1)[0]:
                    try:data+=os.read(fd,65536)
                    except OSError:pass
                # Match actual prompt, not the recorded command header.
                if b'\r\nREADY\r\n' in data and not sent:
                    os.write(fd,b'\x03' if interrupt else b'terminal works\n');sent=True
                done,status_now=os.waitpid(pid,os.WNOHANG)
                if done:status=status_now;break
            assert status is not None, ('terminal command hung',data)
            assert os.waitstatus_to_exitcode(status)==0,data
            assert pathlib.Path(tmp,'restored').read_text()=='True',data
            if not interrupt:assert pathlib.Path(tmp,'answer.txt').read_text()=='terminal works',data
            print('PASS PTY '+('Ctrl+C propagation' if interrupt else 'interactive input')+' and foreground restoration')
        finally:
            if status is None:os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)
            os.close(fd)
