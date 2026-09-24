import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { atlassianRequiredScopes } from '../src/jira.js';
import { confluenceCreateSpace, confluenceStatus } from '../src/confluence.js';
const crypto=webcrypto;
async function environment(scope){
  const secret='test-only-key';
  const te=new TextEncoder();
  const raw=await crypto.subtle.digest('SHA-256',te.encode(`clintware-jira:\0grant:\0${secret}`));
  const key=await crypto.subtle.importKey('raw',raw,{name:'AES-GCM'},false,['encrypt']);
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const grant={scope,access_token:'test-only-token',expires_at:Date.now()+600000,sites:[{id:'test-site'}]};
  const cipher=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:te.encode('clintware-jira:grant:v1')},key,te.encode(JSON.stringify(grant)));
  const sealed_grant=Buffer.from(iv).toString('base64url')+'.'+Buffer.from(cipher).toString('base64url');
  return {JIRA_TOKEN_ENCRYPTION_KEY:secret,REGISTRY_HUB:{getByName:()=>({fetch:async()=>Response.json({sealed_grant})})}};
}
test('space creation rejects an old page-only grant before an upstream write',async()=>{
  const scope=atlassianRequiredScopes().filter(s=>s!=='write:confluence-space').join(' ');
  const env=await environment(scope);
  const status=await confluenceStatus(env);
  assert.equal(status.writable,true);
  assert.equal(status.space_creation_ready,false);
  assert.equal(status.reauthorization_required,true);
  assert.deepEqual((await confluenceCreateSpace(env,{key:'MATRIXMAP',name:'Matrix Map'})).missing_scopes,['write:confluence-space']);
});
test('space creation uses the classic endpoint with the full grant',async(t)=>{
  assert.ok(atlassianRequiredScopes().includes('write:confluence-space'));
  const env=await environment(atlassianRequiredScopes().join(' '));
  t.mock.method(globalThis,'fetch',async(url,options)=>{
    assert.equal(url,'https://api.atlassian.com/ex/confluence/test-site/wiki/rest/api/space');
    assert.equal(options.method,'POST');
    assert.equal(JSON.parse(options.body).key,'MATRIXMAP');
    return Response.json({id:123,key:'MATRIXMAP'});
  });
  assert.equal((await confluenceCreateSpace(env,{key:'MATRIXMAP',name:'Matrix Map'})).ok,true);
});
