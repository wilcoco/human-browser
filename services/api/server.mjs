import {createServer} from 'node:http';
import {mkdirSync,existsSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomBytes,createHmac} from 'node:crypto';
import {ApiError,fail,sourceUrl} from './records.mjs';
import {openDatabase,publish,listPage} from './database.mjs';
const MAX_BODY=256*1024;
export function createApp({db,limits={},trustRailway=false}={}) {
  const buckets=new Map(),salt=randomBytes(32);
  function throttle(req) {
    // Railway's edge supplies X-Railway-Client-IP; never trust arbitrary X-Forwarded-For.
    const address=trustRailway?String(req.headers['x-railway-client-ip']||req.socket.remoteAddress):req.socket.remoteAddress;
    const key=createHmac('sha256',salt).update(address||'unknown').digest('hex');
    const now=Date.now(),minute=Math.floor(now/60000),old=buckets.get(key);
    const bucket=old?.minute===minute?old:{minute,n:0}; bucket.n++; buckets.set(key,bucket);
    if(buckets.size>10000) for(const [k,b] of buckets) if(b.minute!==minute) buckets.delete(k);
    if(buckets.size>20000 || bucket.n>120) fail('rate_limited',429);
  }
  const server=createServer(async(req,res)=>{
    res.setHeader('Content-Type','application/json; charset=utf-8');res.setHeader('Cache-Control','no-store');
    res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
    const send=(code,data)=>{res.writeHead(code);res.end(JSON.stringify(data));};
    try {
      if(req.url.length>25000) fail('url_too_long',414);
      const url=new URL(req.url,'http://localhost');
      if(url.pathname==='/healthz' && req.method==='GET') { db.prepare('SELECT 1').get(); return send(200,{ok:true,version:'0.2.0'}); }
      throttle(req);
      if(url.pathname==='/' && req.method==='GET') return send(200,{name:'사람 브라우저 중앙 API',version:'0.2.0',protocol:'android-local-alpha/1',identity:'device-key; not proof of a unique human',privacy:'Only explicitly published records. No page proxy or AI.',endpoints:['GET /healthz','GET /v1/records?url=…&before=…','POST /v1/records']});
      if(url.pathname==='/v1/records' && req.method==='GET') {
        const source=sourceUrl(url.searchParams.get('url'));
        const raw=url.searchParams.get('before'); const before=raw===null?Number.MAX_SAFE_INTEGER:Number(raw);
        if(raw!==null && (!/^\d+$/.test(raw)||!Number.isSafeInteger(before)||before<=0)) fail('invalid_cursor');
        return send(200,listPage(db,source,before));
      }
      if(url.pathname==='/v1/records' && req.method==='POST') {
        if((req.headers['content-type']||'').split(';')[0].trim()!=='application/json') fail('json_required',415);
        if(Number(req.headers['content-length']||0)>MAX_BODY) fail('body_too_large',413);
        const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;if(size>MAX_BODY) fail('body_too_large',413);chunks.push(chunk);}
        let record;try{record=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{fail('invalid_json');}
        const result=publish(db,record,limits);return send(result.duplicate?200:201,result);
      }
      fail('not_found',404);
    }catch(e){
      if(e instanceof ApiError){if(e.status===429)res.setHeader('Retry-After','60');return send(e.status,{error:e.message});}
      console.error('request_failed',e.code||e.name);send(500,{error:'internal_error'}); // No bodies, URLs, IPs or key material in logs.
    }
  });
  server.requestTimeout=15000;server.headersTimeout=10000;server.keepAliveTimeout=5000;
  server.maxRequestsPerSocket=100;
  return server;
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const directory=process.env.DATA_DIR||'./data';
  if(process.env.NODE_ENV==='production' && (!existsSync(directory)||directory!=='/data')) throw new Error('Mount Railway persistent volume at /data before starting');
  mkdirSync(directory,{recursive:true}); const db=openDatabase(join(directory,'human-browser.sqlite3'));
  const server=createApp({db,trustRailway:process.env.RAILWAY_ENVIRONMENT_ID!==undefined,limits:{blockedActors:(process.env.BLOCKED_ACTORS||'').split(',').filter(Boolean)}});
  server.listen(Number(process.env.PORT||8080),'0.0.0.0',()=>console.log('human_browser_api_ready'));
  const close=()=>server.close(()=>{db.close();process.exit(0);});process.on('SIGTERM',close);process.on('SIGINT',close);
}
