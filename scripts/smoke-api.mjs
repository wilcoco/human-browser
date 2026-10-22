// Only synthetic data on a unique .invalid source; withdraws its own posts afterwards.
import assert from 'node:assert/strict';
import {generateKeyPairSync,randomUUID,sign} from 'node:crypto';
import {canonical,hash} from '../services/api/records.mjs';
const base=process.argv[2];if(!base||!base.startsWith('https://'))throw new Error('Usage: node scripts/smoke-api.mjs https://your-api');
const request=async(path,record)=>{
 const response=await fetch(base+path,{method:record?'POST':'GET',headers:record?{'Content-Type':'application/json'}:{},body:record?JSON.stringify(record):undefined,signal:AbortSignal.timeout(20000)});
 return {status:response.status,body:await response.json()};
};
assert.equal((await request('/healthz')).status,200,'API must be healthy before creating any test data');
const source='https://human-browser.invalid/automated-validation/'+randomUUID();
const key=()=>generateKeyPairSync('ec',{namedCurve:'prime256v1'}),a=key(),b=key();
function make(identity,changes={}){
 const spki=identity.publicKey.export({format:'der',type:'spki'});
 const r={url:source,title:'자동화 검증용 합성 기록',quote:'',capturedAt:new Date().toISOString(),kind:'comment',text:'서버 자동화 시험이며 사람의 의견이 아닙니다.',targetId:'',criterion:'',value:'',disposition:'',relation:'',id:randomUUID(),protocolVersion:'android-local-alpha/1',canonicalization:'android-fixed-string-json/1',algorithm:'SHA256withECDSA/P-256',actorId:'actor:'+hash(spki),publicKey:spki.toString('base64'),createdAt:new Date().toISOString(),operation:'record',withdrawnRecordId:'',...changes};
 r.quoteDigest=hash(r.quote);r.signedPayload=canonical(r);r.signature=sign('sha256',Buffer.from(r.signedPayload),identity.privateKey).toString('base64');return r;
}
const r=make(a),e=make(b,{kind:'evaluation',criterion:'연결 시험',value:'합성 데이터',targetId:r.id});
const withdraw=(identity,original)=>make(identity,{kind:original.kind,operation:'withdrawal',withdrawnRecordId:original.id,text:''});
const page='/v1/records?url='+encodeURIComponent(source);
try{
 assert.equal((await request('/v1/records',r)).status,201);
 assert.equal((await request('/v1/records',r)).status,200);
 assert.equal((await request(page)).body.records[0].id,r.id);
 assert.equal((await request('/v1/records',e)).status,201);
 assert.equal((await request('/v1/records',{...r,text:'tampered'})).status,400);
 assert.equal((await request('/v1/records',withdraw(b,r))).status,403);
 assert.equal((await request('/v1/records',withdraw(a,r))).status,201);
 assert.equal((await request(page)).body.records[0].id,e.id);
 console.log('Live HTTPS: publication, idempotency, cross-key evaluation, forged payload rejection and owner withdrawal passed.');
}finally{
 await request('/v1/records',withdraw(a,r));await request('/v1/records',withdraw(b,e));
}
assert.equal((await request(page)).body.records.length,0);
console.log('Synthetic records withdrawn; immutable audit history retained.');
