#!/usr/bin/env node
'use strict';
// Real Chromium/HTTP regression checks. Requires playwright or playwright-core.
// node tests/dashboard.cjs /absolute/path/to/annalist
// Optional CHROMIUM_EXECUTABLE_PATH selects an installed browser.
// Synthetic HOME/XDG data only; screenshots/report are retained under /tmp.
const fs=require('fs'), path=require('path'), os=require('os'), net=require('net'), http=require('http');
const {spawn,spawnSync}=require('child_process');
let chromium;
try { ({chromium}=require('playwright')); } catch { ({chromium}=require('playwright-core')); }
const binary=process.argv[2]&&path.resolve(process.argv[2]);
if(!binary||!fs.existsSync(binary)){console.error('Usage: node '+process.argv[1]+' /absolute/path/to/annalist');process.exit(2)}
const root=fs.mkdtempSync(path.join(os.tmpdir(),'annalist-dashboard-release-check-'));
const project=path.join(root,'project'),data=path.join(root,'data');fs.mkdirSync(project);fs.mkdirSync(data);
const env={...process.env,HOME:path.join(root,'home'),XDG_DATA_HOME:data};fs.mkdirSync(env.HOME);const report={binary,artifacts:root,checks:[],errors:[]};let server,browser;
function check(name,ok,evidence){report.checks.push({name,passed:!!ok,evidence});}
function run(args){const r=spawnSync(binary,args,{cwd:project,env,encoding:'utf8',timeout:30000});if(r.status!==0)throw Error('CLI '+args[0]+' failed: '+r.stderr+' '+r.error);return r.stdout}
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function freePort(){return new Promise((resolve,reject)=>{const s=net.createServer();s.on('error',reject);s.listen(0,'127.0.0.1',()=>{const port=s.address().port;s.close(()=>resolve(port))})})}
async function main(){
 run(['init']);const port=await freePort();fs.appendFileSync(path.join(project,'.annalist/config.toml'),'\n[ui]\nport = '+port+'\n');
 const names=['normal.txt','quote" onmouseover="window.__xss=1','file..txt'];for(const name of names)fs.writeFileSync(path.join(project,name),'before\n');
 for(const name of names)run(['run','--','python3','-c','from pathlib import Path; import sys; Path(sys.argv[1]).write_text("after\\n")'+(name==='normal.txt'?';# '+ 'long-command-'.repeat(100):''),name]);
 // Seed a high-volume file history and non-UTF-8 text using synthetic data only.
 fs.writeFileSync(path.join(project,'big.txt'),'a'.repeat(200*1024));
 fs.writeFileSync(path.join(project,'invalid.txt'),Buffer.from([255,128,1]));
 run(['run','--','python3','-c','from pathlib import Path; Path("big.txt").write_text("b"*(200*1024)); Path("invalid.txt").write_bytes(bytes([255,128,2]))']);
 const seeded=spawnSync('python3',['-c',`import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
r=c.execute("select session_id,ts,type,path,prev_path,prev_hash,new_hash,size from events where path='big.txt' order by id desc limit 1").fetchone()
for i in range(120):c.execute('insert into events(session_id,seq,ts,type,path,prev_path,prev_hash,new_hash,size) values(?,?,?,?,?,?,?,?,?)',(r[0],100+i,*r[1:]))
c.commit()`,path.join(data,'annalist','annalist.db')],{encoding:'utf8'});
 if(seeded.status!==0)throw Error('fixture setup failed: '+seeded.stderr);
 const out=fs.openSync(path.join(root,'server.log'),'w');server=spawn(binary,['ui'],{cwd:project,env,stdio:['ignore',out,out]});fs.closeSync(out);
 const url='http://127.0.0.1:'+port;let ready=false;for(let i=0;i<50;i++){try{if((await fetch(url+'/api/project')).ok){ready=true;break}}catch{}await sleep(100)}if(!ready)throw Error('Server did not become ready');
 const request=(resource,headers={})=>new Promise((resolve,reject)=>{const req=http.get(url+resource,{headers},r=>{r.resume();r.on('end',()=>resolve({status:r.statusCode}))});req.on('error',reject);req.setTimeout(4000,()=>req.destroy(Error('HTTP request timed out')))});
 for(const [name,resource,headers,allowed] of [
  ['malformed percent request does not crash','/api/files/history?session=1&path=%A',{},[200,400]],
  ['hostile Host rejected','/api/sessions',{Host:'evil.example'},[403]],
  ['hostile Origin rejected','/api/sessions',{Origin:'http://evil.example'},[403]],
  ['cross-site fetch rejected','/api/sessions',{'Sec-Fetch-Site':'cross-site'},[403]],
  ['invalid authority rejected','/api/sessions',{Host:'127.0.0.1:'+port+'.evil.example'},[400,403]],
 ]){const r=await request(resource,headers);check(name,allowed.includes(r.status),r.status)}
 const rawRequest=(raw)=>new Promise((resolve,reject)=>{const s=net.connect(port,'127.0.0.1');let body='';s.setTimeout(4000);s.on('connect',()=>s.write(raw));s.on('data',b=>body+=b);s.on('end',()=>resolve(body));s.on('error',reject);s.on('timeout',()=>{s.destroy();reject(Error('raw request timed out'))})});
 const duplicate=await rawRequest('GET /api/sessions HTTP/1.1\r\nHost: 127.0.0.1:'+port+'\r\nHost: localhost:'+port+'\r\n\r\n');check('duplicate Host rejected',duplicate.startsWith('HTTP/1.1 400'));
 const bodyHeader=await rawRequest('GET /api/sessions HTTP/1.1\r\nHost: 127.0.0.1:'+port+'\r\n\r\nOrigin: http://evil.example\r\n');check('header parser stops at end of headers',bodyHeader.startsWith('HTTP/1.1 200'));
 const slow=net.connect(port,'127.0.0.1');await new Promise(r=>slow.once('connect',r));slow.on('error',()=>{});slow.write('G');const tick=setInterval(()=>{if(!slow.destroyed)slow.write('a')},75);const started=Date.now();await sleep(100);const healthy=await fetch(url+'/api/project');await healthy.arrayBuffer();const elapsed=Date.now()-started;clearInterval(tick);slow.destroy();check('absolute slow-header deadline',healthy.ok&&elapsed<3000,{elapsed});
 for(const authority of ['127.0.0.1','localhost:'+ (port+1),'127.0.0.1:'+port+':evil','127.0.0.1:'+port+'@evil']){const r=await request('/api/sessions',{Host:authority});check('reject invalid authority '+authority,r.status===403,r.status)}
 for(const resource of ['../escape','a/../escape','/tmp/escape','.git/HEAD','.annalist/config.toml']){const r=await fetch(url+'/api/files/history?session=1&path='+encodeURIComponent(resource));await r.arrayBuffer();check('reject unsafe history path '+resource,r.status===400,r.status)}
 const bounded=await fetch(url+'/api/files/history?session=4&path=big.txt');const boundedText=await bounded.text(),boundedHistory=JSON.parse(boundedText);check('file-history event cap',boundedHistory.length===100,boundedHistory.length);check('aggregate encoded preview cap',Buffer.byteLength(boundedText)<2*1024*1024+64*1024&&boundedHistory.some(h=>h.preview_limited),Buffer.byteLength(boundedText));
 const invalid=await (await fetch(url+'/api/files/history?session=4&path=invalid.txt')).json();check('non-UTF-8 blob omitted from text previews',invalid[0].before===null&&invalid[0].after===null);
 browser=await chromium.launch({headless:true,...(process.env.CHROMIUM_EXECUTABLE_PATH?{executablePath:process.env.CHROMIUM_EXECUTABLE_PATH}:{}),args:process.getuid?.()===0?['--no-sandbox']:[]});const p=await browser.newPage({viewport:{width:1440,height:1000}});p.on('pageerror',e=>report.errors.push(e.message));
 await p.goto(url);await p.locator('#rows tr').first().waitFor();check('four real recordings',await p.locator('#rows tr').count()===4);
 const dims=await p.evaluate(()=>{const t=document.querySelector('#runs').getBoundingClientRect(),c=document.querySelector('#runs').parentElement.getBoundingClientRect();return{tableRight:t.right,panelRight:c.right,viewport:innerWidth}});check('desktop table contained',dims.tableRight<=dims.panelRight+1&&dims.tableRight<=dims.viewport,dims);await p.screenshot({path:path.join(root,'history-desktop.png'),fullPage:true});
 await p.locator('#search').fill('unfindable-test-phrase');check('no search results',await p.locator('#noresults').isVisible());await p.locator('#clear').click();
 await p.locator('#search').fill('onmouseover');await p.locator('#rows button').click();await p.locator('#files button').first().waitFor();check('hostile name is text',await p.locator('#files [onmouseover]').count()===0,await p.locator('#files').textContent());
 await p.locator('#files button').click();await p.locator('#version-content pre').first().waitFor();const versions=await p.locator('#version-content pre').allTextContents();check('before and after content',versions.includes('before\n')&&versions.includes('after\n'),versions);await p.locator('#files button').hover();check('no hostile filename execution',await p.evaluate(()=>!window.__xss));await p.screenshot({path:path.join(root,'detail-desktop.png'),fullPage:true});
 await p.locator('#close-file').click();check('file history closes',!await p.locator('#versions').isVisible());
 await p.locator('#back').click();await p.locator('#search').fill('file..txt');await p.locator('#rows button').click();await p.locator('#files button').first().waitFor();await p.locator('#files button').click();await p.waitForFunction(()=>document.querySelector('#version-content pre')||document.querySelector('#version-content .error'));check('legitimate double-dot filename preview',await p.locator('#version-content pre').count()>=2,await p.locator('#version-content').textContent());
 await p.locator('#back').click();await p.locator('#search').fill('big.txt');await p.locator('#rows button').click();await p.locator('#files button').filter({hasText:'big.txt'}).click();await p.locator('#version-content .notice').first().waitFor();check('large history limits explained in dashboard',(await p.locator('#version-content .notice').allTextContents()).some(t=>t.includes('2 MiB')));await p.locator('#close-file').click();
 await p.setViewportSize({width:390,height:844});await p.locator('#nav-history').click();await p.locator('#search').fill('');const mobile=await p.evaluate(()=>({client:document.documentElement.clientWidth,scroll:document.documentElement.scrollWidth}));check('mobile no horizontal overflow',mobile.scroll<=mobile.client,mobile);await p.screenshot({path:path.join(root,'history-mobile.png'),fullPage:true});
 await p.locator('#nav-guide').focus();await p.keyboard.press('Enter');check('keyboard guide navigation',await p.locator('#guide').isVisible());await p.screenshot({path:path.join(root,'guide-mobile.png'),fullPage:true});
 await p.route('**/api/sessions',r=>r.fulfill({status:500,body:'synthetic failure'}));await p.locator('#nav-history').click();await p.locator('#refresh').click();await p.locator('#error').waitFor();check('HTTP error displayed',await p.locator('#error').isVisible());await p.unroute('**/api/sessions');await p.locator('#refresh').click();await p.locator('#error').waitFor({state:'hidden'});check('error retry recovers',true);
 await p.route('**/api/sessions',r=>r.fulfill({status:200,contentType:'application/json',body:'[]'}));await p.locator('#refresh').click();await p.locator('#empty').waitFor();check('empty project onboarding',await p.locator('#empty').isVisible());await p.screenshot({path:path.join(root,'empty-mobile.png'),fullPage:true});
 check('no browser JavaScript errors',report.errors.length===0,report.errors);
}
main().catch(e=>{report.fatal=e.stack;process.exitCode=1}).finally(async()=>{if(browser)await browser.close();if(server&&!server.killed)server.kill('SIGTERM');fs.writeFileSync(path.join(root,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));if(report.checks.some(c=>!c.passed))process.exitCode=1});
