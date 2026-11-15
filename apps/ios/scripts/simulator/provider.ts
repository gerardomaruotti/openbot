import { chmod, writeFile } from "node:fs/promises";
import { join } from "node:path";

/** A deterministic app-server executable. It never starts a shell, model or external service. */
export async function writeProvider(root: string): Promise<string> {
  const path = join(root, "synthetic-codex.cjs");
  const source = String.raw`#!${process.execPath}
const fs = require('node:fs');
const readline = require('node:readline');
const root = ${JSON.stringify(root)};
let threads = 0, turns = 0;
const waiting = new Map();
const interrupted = new Set();
const write = value => process.stdout.write(JSON.stringify(value) + '\n');
const notify = (method, params) => write({method, params});
const later = (ms, fn) => setTimeout(fn, ms);
function toolValue(result) {
  for (const item of result?.contentItems||[]) {
    if (item.type!=='inputText') continue;
    try { const value=JSON.parse(item.text); if (value && typeof value==='object') return value; } catch {}
  }
  return {};
}
function browserSecret(threadId,turnId,tabId) {
  const id='browser-secret-'+turnId;
  waiting.set(id,{threadId,turnId,kind:'browser'});
  write({id,method:'item/tool/call',params:{threadId,turnId,callId:id,namespace:'openbot_browser',tool:'submit_secret',
    arguments:{tabId,method:'password',targets:[{kind:'role',role:'textbox',name:'Synthetic password'}],submission:'enter'}}});
}
if (process.argv.includes('--version')) { process.stdout.write('codex-cli 0.156.0\n'); process.exit(0); }
function finish(threadId, turnId, text) {
  if (interrupted.has(turnId)) return;
  const id = 'answer-' + turnId;
  notify('item/started', {threadId, turnId, item:{id,type:'agentMessage',phase:'final_answer',text:''}});
  const streaming = text.startsWith('SIM-STREAM-1');
  const chunks = streaming ? ['SIM-STREAM-1 partial', ' and complete'] : [text.slice(0,Math.ceil(text.length/2)), text.slice(Math.ceil(text.length/2))];
  const completeText = chunks.join('');
  later(150, () => { if (!interrupted.has(turnId)) notify('item/agentMessage/delta',{threadId,turnId,itemId:id,delta:chunks[0]}); });
  const complete = () => {
    if (interrupted.has(turnId)) return;
    notify('item/agentMessage/delta',{threadId,turnId,itemId:id,delta:chunks[1]});
    notify('item/completed',{threadId,turnId,item:{id,type:'agentMessage',phase:'final_answer',text:completeText}});
    notify('turn/completed',{threadId,turn:{id:turnId,status:'completed'}});
  };
  if (streaming) {
    const watcher = fs.watch(root, (_, name) => {
      if (name === 'release-stream') { watcher.close(); complete(); }
    });
  } else { later(1000, complete); }
}
readline.createInterface({input:process.stdin}).on('line',line=>{
  const m=JSON.parse(line), p=m.params||{};
  if (!m.method) {
    const pending=waiting.get(String(m.id));
    if (pending) {
      waiting.delete(String(m.id));
      if (pending.kind === 'prompt') {
        const answers=m.result?.answers||{};
        const values=id=>Array.isArray(answers[id]?.answers)?answers[id].answers:[];
        const cancelled=Object.keys(answers).length===0;
        const metadata={requestId:String(m.id),threadId:pending.threadId,turnId:pending.turnId,cancelled,
          answerCounts:Object.fromEntries(['color','sizes','note','private-code'].map(id=>[id,values(id).length])),
          expectedColor:JSON.stringify(values('color'))===JSON.stringify(['Blue']),
          expectedSizes:JSON.stringify([...values('sizes')].sort())===JSON.stringify(['Large','Small']),
          freeTextReceived:values('note').some(value=>typeof value==='string'&&value.length>0),
          secretReceived:values('private-code').some(value=>typeof value==='string'&&value.length>0)};
        // Counts and fixed-choice checks only. Private and free-text values never leave this process.
        fs.appendFileSync(root+'/provider-prompt-answers.jsonl',JSON.stringify(metadata)+'\n');
        finish(pending.threadId,pending.turnId,cancelled?'SIM-QUESTION cancelled':'SIM-QUESTION answered');
      } else if (pending.kind === 'confirm') {
        const value=toolValue(m.result);
        const actionId=['send','keep'].includes(value.actionId)?value.actionId:null;
        const sender=['Personal','Work'].includes(value.values?.sender)?value.values.sender:null;
        const metadata={requestId:String(m.id),threadId:pending.threadId,turnId:pending.turnId,
          success:m.result?.success===true,status:['answered','skipped','expired'].includes(value.status)?value.status:null,
          actionId,sender,cancelled:value.status!=='answered'||actionId==='keep'};
        // This is the real ask_ui result. No draft is sent, and no free text is recorded.
        fs.appendFileSync(root+'/provider-confirm-answers.jsonl',JSON.stringify(metadata)+'\n');
        finish(pending.threadId,pending.turnId,value.status!=='answered'?'SIM-CONFIRM cancelled':actionId==='send'?'SIM-CONFIRM answered':'SIM-CONFIRM kept');
      } else if (pending.kind === 'browser-open') {
        const value=toolValue(m.result);
        if (m.result?.success===true && typeof value.tabId==='string') browserSecret(pending.threadId,pending.turnId,value.tabId);
        else finish(pending.threadId,pending.turnId,'SIM-BROWSER unavailable');
      } else if (pending.kind === 'browser') {
        const value=toolValue(m.result);
        const metadata={requestId:String(m.id),threadId:pending.threadId,turnId:pending.turnId,
          success:m.result?.success===true,cancelled:value.status==='cancelled',status:['cancelled','completed'].includes(value.status)?value.status:null};
        fs.appendFileSync(root+'/provider-browser-answers.jsonl',JSON.stringify(metadata)+'\n');
        finish(pending.threadId,pending.turnId,value.status==='cancelled'?'SIM-BROWSER cancelled':'SIM-BROWSER resolved');
      } else { finish(pending.threadId,pending.turnId,m.result?.decision==='accept'?'SIM-APPROVAL accepted':'SIM-APPROVAL declined'); }
    }
    return;
  }
  if (m.id === undefined) return;
  const reply=result=>write({id:m.id,result});
  switch(m.method) {
    case 'initialize': return reply({});
    case 'account/read':return reply({account:{type:'chatgpt',email:'synthetic@example.invalid'}});
    case 'account/rateLimits/read':return reply({rateLimits:{limitId:'codex',primary:null,secondary:null},rateLimitsByLimitId:null});
    case 'model/list':return reply({data:[{id:'synthetic-native',model:'gpt-6-luna',displayName:'Synthetic fixture'}]});
    case 'plugin/list':return reply({marketplaces:[]});
    case 'config/read':return reply({config:{mcp_servers:{}},layers:[{name:{type:'user',file:root+'/codex-config.toml',profile:null},version:'1',config:{mcp_servers:{}}}]});
    case 'config/batchWrite':return reply({});
    case 'thread/start':return reply({thread:{id:'sim-thread-'+(++threads),turns:[]}});
    case 'thread/resume':return reply({thread:{id:p.threadId,turns:[]}});
    case 'thread/read':return reply({thread:{id:p.threadId,turns:[]}});
    case 'thread/turns/list':case 'thread/items/list':return reply({data:[],nextCursor:null});
    case 'thread/archive':case 'thread/name/set':return reply({});
    case 'thread/unsubscribe':return reply({status:'Unsubscribed'});
    case 'turn/interrupt':
      interrupted.add(p.turnId);
      for (const [id,pending] of waiting) if (pending.turnId===p.turnId) waiting.delete(id);
      reply({});return notify('turn/completed',{threadId:p.threadId,turn:{id:p.turnId,status:'interrupted'}});
    case 'turn/start': {
      const turnId='sim-turn-'+(++turns),threadId=p.threadId;
      const text=(p.input||[]).filter(v=>v.type==='text').map(v=>v.text).join('\n');
      fs.appendFileSync(root+'/provider-turns.jsonl',JSON.stringify({turnId,threadId,text})+'\n');
      reply({turn:{id:turnId,status:'inProgress',items:[]}});
      notify('turn/started',{threadId,turn:{id:turnId,status:'inProgress'}});
      notify('item/completed',{threadId,turnId,item:{id:'thinking-'+turnId,type:'agentMessage',phase:'commentary',text:'SIM-COMMENTARY-HIDDEN'}});
      const marker=text.includes('SIM-BROWSER-RELOAD')?'SIM-BROWSER-RELOAD':(text.match(/SIM-[A-Z]+(?:-[0-9]+)?/g)||['SIM-REPLY']).at(-1);
      if (marker==='SIM-APPROVAL') {
        const id='approve-'+turnId;waiting.set(id,{threadId,turnId,kind:'approval'});
        later(100,()=>write({id,method:'item/commandExecution/requestApproval',params:{threadId,turnId,itemId:'command-'+turnId,command:'printf simulator-only',cwd:root,reason:'Synthetic approval; no command will execute.'}}));
      } else if (marker==='SIM-CONFIRM') {
        const id='confirm-'+turnId;waiting.set(id,{threadId,turnId,kind:'confirm'});
        const block={type:'confirm',title:'Send synthetic draft?',
          fields:[{label:'To',value:'recipient@example.invalid'},{label:'From',select:'sender',options:['Personal','Work']}],
          preview:'Synthetic draft for a simulator check.\n\n'+'This synthetic paragraph is part of the complete draft preview. No message will be sent.\n'.repeat(32)+'\nSIM-CONFIRM-TAIL',
          actions:[{id:'send',label:'Send synthetic draft',style:'primary',confirm:true},{id:'keep',label:'Keep draft',style:'secondary'}]};
        later(100,()=>write({id,method:'item/tool/call',params:{threadId,turnId,callId:id,namespace:'openbot',tool:'ask_ui',arguments:{blockId:'sim-confirm-'+turnId,block}}}));
      } else if (marker==='SIM-FAIL') {
        later(150,()=>{
          fs.appendFileSync(root+'/provider-failed-turns.jsonl',JSON.stringify({threadId,turnId})+'\n');
          notify('turn/completed',{threadId,turn:{id:turnId,status:'failed',error:{message:'Synthetic request failed. No external action was performed.',codexErrorInfo:'other'}}});
        });
      } else if ((marker==='SIM-BROWSER'||marker==='SIM-BROWSER-RELOAD')) {
        const id='browser-open-'+turnId;waiting.set(id,{threadId,turnId,kind:'browser-open'});
        later(100,()=>write({id,method:'item/tool/call',params:{threadId,turnId,callId:id,namespace:'openbot_browser',tool:'open',arguments:{url:marker==='SIM-BROWSER-RELOAD'?'https://example.invalid/sign-in-reload':'https://example.invalid/sign-in'}}}));
      } else if (marker==='SIM-QUESTION') {
        const id='prompt-'+turnId;waiting.set(id,{threadId,turnId,kind:'prompt'});
        const questions=[
          {id:'color',header:'Color',question:'Choose a color. '+ 'The complete question must be shown before you answer. '.repeat(6),isSecret:false,
            options:[{label:'Blue',description:'Cool color'},{label:'Red',description:'Warm color'}]},
          {id:'sizes',header:'Sizes',question:'Choose all required sizes.',isSecret:false,multiSelect:true,
            options:[{label:'Small',description:'Small size'},{label:'Large',description:'Large size'}]},
          {id:'note',header:'Note',question:'Add a short note.',isSecret:false,options:null},
          {id:'private-code',header:'Private code',question:'Enter a synthetic private code.',isSecret:true,options:null}
        ];
        later(100,()=>write({id,method:'item/tool/requestUserInput',params:{threadId,turnId,itemId:'question-'+turnId,questions}}));
      } else { finish(threadId,turnId,marker+' received'); }
      return;
    }
    default:return write({id:m.id,error:{code:-32601,message:'Unsupported synthetic method: '+m.method}});
  }
});
`;
  await writeFile(path, source, { mode: 0o700 });
  await chmod(path, 0o700);
  return path;
}
