import {createPublicKey, createHash, verify} from 'node:crypto';
export class ApiError extends Error { constructor(status, code) { super(code); this.status=status; } }
export const fail = (code, status=400) => { throw new ApiError(status, code); };
export const canonical = value => JSON.stringify(Object.fromEntries(Object.keys(value).sort().map(k=>[k,value[k]]))).replaceAll('/', '\\/');
export const hash = value => createHash('sha256').update(value).digest('hex');
const draftFields = ['url','title','quote','capturedAt','kind','text','targetId','criterion','value','disposition','relation'];
const fields = [...draftFields,'id','protocolVersion','canonicalization','algorithm','actorId','publicKey','createdAt','operation','withdrawnRecordId','quoteDigest'].sort();
export const uuid = value => typeof value==='string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
export function sourceUrl(value) {
  if(typeof value!=='string' || Buffer.byteLength(value)>8192 || /[\u0000-\u0020\u007f]/u.test(value)) fail('invalid_url');
  let u; try { u = new URL(value); } catch { fail('invalid_url'); }
  if(!['http:','https:'].includes(u.protocol) || !u.hostname || u.username || u.password) fail('invalid_url');
  return value; // Exact original URL. No silent query removal or site merging.
}
function base64(value, max) {
  if(typeof value!=='string' || value.length>max || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) fail('invalid_encoding');
  const b=Buffer.from(value,'base64'); if(b.toString('base64')!==value) fail('invalid_encoding'); return b;
}
export function validateRecord(record) {
  if(!record || typeof record!=='object' || Array.isArray(record) || Object.keys(record).sort().join()!==[...fields,'signature','signedPayload'].sort().join()) fail('invalid_fields');
  for(const [key,value] of Object.entries(record)) {
    if(typeof value!=='string' || /\u0000|[\uD800-\uDFFF]/u.test(value)) fail('invalid_text');
    const max=key==='signedPayload'?131072:['text','quote'].includes(key)?32768:key==='url'?8192:2048;
    if(Buffer.byteLength(value)>max) fail('field_too_long');
  }
  let payload; try{payload=JSON.parse(record.signedPayload);}catch{fail('invalid_payload');}
  if(!payload || Array.isArray(payload) || Object.keys(payload).sort().join()!==fields.join() || fields.some(k=>payload[k]!==record[k])) fail('payload_mismatch');
  if(canonical(payload)!==record.signedPayload) fail('noncanonical_payload');
  if(record.protocolVersion!=='android-local-alpha/1' || record.canonicalization!=='android-fixed-string-json/1' || record.algorithm!=='SHA256withECDSA/P-256') fail('unsupported_protocol');
  if(!uuid(record.id)) fail('invalid_id'); sourceUrl(record.url);
  for(const k of ['createdAt','capturedAt']) if(!/^\d{4}-\d{2}-\d{2}T.*Z$/.test(record[k]) || !Number.isFinite(Date.parse(record[k]))) fail('invalid_timestamp');
  if(record.quoteDigest!==hash(record.quote)) fail('quote_digest_mismatch');
  const spki=base64(record.publicKey,256); let key;
  try{key=createPublicKey({key:spki,format:'der',type:'spki'});}catch{fail('invalid_key');}
  if(key.asymmetricKeyType!=='ec' || key.asymmetricKeyDetails?.namedCurve!=='prime256v1' || record.actorId!=='actor:'+hash(spki)) fail('invalid_identity');
  let valid=false; try{valid=verify('sha256',Buffer.from(record.signedPayload),key,base64(record.signature,160));}catch{}
  if(!valid) fail('invalid_signature',401);
  if(!['comment','question','answer','evaluation','relation','decision'].includes(record.kind)) fail('invalid_kind');
  if(record.operation==='withdrawal') {
    if(!uuid(record.withdrawnRecordId) || ['text','targetId','criterion','value','disposition','relation'].some(k=>record[k]!=='')) fail('invalid_withdrawal');
  } else if(record.operation==='record') {
    if(record.withdrawnRecordId!=='') fail('invalid_withdrawal');
    if(['comment','question','answer','relation'].includes(record.kind) && !record.text.trim()) fail('text_required');
    if(record.kind==='evaluation' ? !record.criterion.trim() || !record.value.trim() : record.criterion!=='' || record.value!=='') fail('invalid_evaluation');
    if(record.targetId && (!uuid(record.targetId) || !['answer','evaluation','relation'].includes(record.kind))) fail('invalid_target');
    if(record.kind==='relation' ? !record.targetId || !record.relation.trim() : record.relation!=='') fail('invalid_relation');
    if(record.kind==='decision' ? !record.disposition.trim() : record.disposition!=='') fail('invalid_decision');
  } else fail('invalid_operation');
  return record;
}
