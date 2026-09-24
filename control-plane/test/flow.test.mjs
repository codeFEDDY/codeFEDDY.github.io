import test from "node:test";
import assert from "node:assert/strict";
import { normalizeWorkflow, runWorkflowDefinition } from "../src/flow.js";

test("rejects credential values in stored workflow definitions",()=>{
  assert.throws(()=>normalizeWorkflow({
    product:"demo",
    name:"bad-secret",
    steps:[{id:"x",type:"set",values:{api_key:"not-allowed"}}]
  }),/credential_value_field_rejected/);
});

test("allows credential references without secret values",()=>{
  const flow=normalizeWorkflow({
    product:"demo",
    name:"credential-ref",
    steps:[{id:"x",type:"set",values:{credential_ref:"crm-production"}}]
  });
  assert.equal(flow.steps[0].values.credential_ref,"crm-production");
});

test("approval step pauses until explicitly approved",async()=>{
  const flow=normalizeWorkflow({
    product:"demo",
    name:"approval",
    steps:[
      {id:"start",type:"emit",event:"start"},
      {id:"approve",type:"approval",message:"Approve action"},
      {id:"done",type:"emit",event:"done"}
    ]
  });
  const emitted=[];
  const first=await runWorkflowDefinition({workflow:flow,input:{},emit:async e=>emitted.push(e.event)});
  assert.equal(first.status,"approval_required");
  assert.deepEqual(emitted,["start"]);

  emitted.length=0;
  const second=await runWorkflowDefinition({workflow:flow,input:{},approvedSteps:["approve"],emit:async e=>emitted.push(e.event)});
  assert.equal(second.status,"succeeded");
  assert.deepEqual(emitted,["start","done"]);
});

test("capability steps resolve input bindings and use the supplied runner",async()=>{
  const flow=normalizeWorkflow({
    product:"demo",
    name:"capability",
    steps:[{
      id:"write",
      type:"capability",
      capability:"repo.file.write",
      resource:{path:"demo/{{input.name}}.txt",content:"{{input.body}}"},
      reason:"test"
    }]
  });
  let call=null;
  const run=await runWorkflowDefinition({
    workflow:flow,
    input:{name:"sample",body:"hello"},
    capabilityRunner:async args=>{
      call=args;
      return {ok:true,status:"executed",result:{ok:true,commit_sha:"abc"}};
    }
  });
  assert.equal(run.status,"succeeded");
  assert.equal(call.resource.path,"demo/sample.txt");
  assert.equal(call.resource.content,"hello");
});
