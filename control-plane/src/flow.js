const FLOW_TYPES = new Set(["set","emit","approval","capability"]);
const TRIGGER_TYPES = new Set(["manual","webhook","schedule","event"]);
const MAX_STEPS = 64;
const MAX_TEXT = 8000;

const clip = (value,max=MAX_TEXT) => String(value ?? "").slice(0,max);
export const normalizeFlowName = (value) => String(value||"").trim().toLowerCase().replace(/[^a-z0-9._-]/g,"-").replace(/-+/g,"-").replace(/^-|-$/g,"").slice(0,120);

function cloneJson(value){
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function tokenShaped(value){
  const s=String(value||"");
  return /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b/.test(s)
    || /\bgithub_pat_[A-Za-z0-9_]{20,}\b/.test(s)
    || /\bsk-[A-Za-z0-9_-]{20,}\b/.test(s)
    || /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/.test(s)
    || /\bBearer\s+[A-Za-z0-9._~+\/-]{24,}\b/i.test(s);
}

function inspectForSecrets(value,path="workflow"){
  if(value===null||value===undefined)return;
  if(typeof value==="string"){
    if(tokenShaped(value))throw new Error("secret_shaped_value_rejected:"+path);
    return;
  }
  if(Array.isArray(value)){
    value.forEach((v,i)=>inspectForSecrets(v,path+"["+i+"]"));
    return;
  }
  if(typeof value==="object"){
    for(const [key,val] of Object.entries(value)){
      const lower=key.toLowerCase();
      const isReference=/(?:_ref|reference|credential_ref|secret_ref)$/.test(lower);
      if(!isReference&&/(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization|cookie|session[_-]?id|private[_-]?key)/.test(lower)){
        throw new Error("credential_value_field_rejected:"+path+"."+key);
      }
      inspectForSecrets(val,path+"."+key);
    }
  }
}

function normalizeStep(step,index){
  const type=String(step?.type||"").trim().toLowerCase();
  if(!FLOW_TYPES.has(type))throw new Error("unsupported_step_type:"+type);
  const id=normalizeFlowName(step?.id||("step-"+(index+1)));
  if(!id)throw new Error("step_id_required");

  const out={id,type};
  if(type==="set"){
    out.values=cloneJson(step.values&&typeof step.values==="object"?step.values:{});
  }else if(type==="emit"){
    out.event=clip(step.event||id,160);
    out.metadata=cloneJson(step.metadata&&typeof step.metadata==="object"?step.metadata:{});
  }else if(type==="approval"){
    out.message=clip(step.message||"Approval required",1200);
  }else if(type==="capability"){
    out.capability=clip(step.capability,160);
    if(!out.capability)throw new Error("capability_required:"+id);
    out.resource=cloneJson(step.resource&&typeof step.resource==="object"?step.resource:{});
    out.reason=clip(step.reason||"",1200);
    out.message=clip(step.message||"",1200);
  }
  inspectForSecrets(out,"step."+id);
  return out;
}

export function normalizeWorkflow(body={}){
  const name=normalizeFlowName(body.name||body.id||"");
  const product=normalizeFlowName(body.product||"");
  if(!name)throw new Error("workflow_name_required");
  if(!product)throw new Error("workflow_product_required");

  const triggerType=String(body.trigger?.type||"manual").toLowerCase();
  if(!TRIGGER_TYPES.has(triggerType))throw new Error("unsupported_trigger_type:"+triggerType);

  const steps=Array.isArray(body.steps)?body.steps.slice(0,MAX_STEPS).map(normalizeStep):[];
  if(!steps.length)throw new Error("workflow_steps_required");
  const ids=new Set();
  for(const step of steps){
    if(ids.has(step.id))throw new Error("duplicate_step_id:"+step.id);
    ids.add(step.id);
  }

  const workflow={
    name,
    product,
    title:clip(body.title||name,180),
    description:clip(body.description||"",2000),
    version:Math.max(1,Math.min(100000,Number(body.version)||1)),
    enabled:body.enabled!==false,
    trigger:{
      type:triggerType,
      schedule:clip(body.trigger?.schedule||"",240),
      event:clip(body.trigger?.event||"",240)
    },
    steps,
    updated_at:new Date().toISOString()
  };
  inspectForSecrets(workflow);
  return workflow;
}

function getPath(root,path){
  const parts=String(path||"").split(".").filter(Boolean);
  let value=root;
  for(const part of parts){
    if(value===null||value===undefined)return "";
    value=value[part];
  }
  return value===undefined||value===null?"":value;
}

function resolveString(value,context){
  return String(value).replace(/\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}/g,(_,key)=>{
    const resolved=getPath(context,key);
    return typeof resolved==="object"?JSON.stringify(resolved):String(resolved);
  });
}

export function resolveBindings(value,context){
  if(typeof value==="string")return resolveString(value,context);
  if(Array.isArray(value))return value.map(v=>resolveBindings(v,context));
  if(value&&typeof value==="object"){
    const out={};
    for(const [k,v] of Object.entries(value))out[k]=resolveBindings(v,context);
    return out;
  }
  return value;
}

export async function runWorkflowDefinition({
  workflow,
  input={},
  approvedSteps=[],
  capabilityRunner,
  emit
}){
  if(!workflow?.enabled)return {ok:false,status:"disabled",error:"workflow_disabled"};
  const approved=new Set((Array.isArray(approvedSteps)?approvedSteps:[]).map(normalizeFlowName));
  const runId=crypto.randomUUID();
  const startedAt=new Date().toISOString();
  const context={input:cloneJson(input)||{},values:{},steps:{}};
  const results=[];

  for(const step of workflow.steps||[]){
    const started=Date.now();

    if(step.type==="set"){
      const values=resolveBindings(step.values||{},context);
      Object.assign(context.values,values);
      const record={step_id:step.id,type:step.type,status:"succeeded",duration_ms:Date.now()-started,output:values};
      results.push(record);
      context.steps[step.id]=record;
      continue;
    }

    if(step.type==="emit"){
      const metadata=resolveBindings(step.metadata||{},context);
      if(emit)await emit({event:step.event,metadata,run_id:runId,step_id:step.id});
      const record={step_id:step.id,type:step.type,status:"succeeded",duration_ms:Date.now()-started,output:{event:step.event}};
      results.push(record);
      context.steps[step.id]=record;
      continue;
    }

    if(step.type==="approval"){
      if(!approved.has(step.id)){
        const record={step_id:step.id,type:step.type,status:"approval_required",duration_ms:Date.now()-started,message:step.message};
        results.push(record);
        return {
          ok:false,
          status:"approval_required",
          run_id:runId,
          workflow:workflow.name,
          product:workflow.product,
          started_at:startedAt,
          stopped_at:new Date().toISOString(),
          approval:{step_id:step.id,message:step.message},
          results
        };
      }
      const record={step_id:step.id,type:step.type,status:"approved",duration_ms:Date.now()-started};
      results.push(record);
      context.steps[step.id]=record;
      continue;
    }

    if(step.type==="capability"){
      if(typeof capabilityRunner!=="function")throw new Error("capability_runner_required");
      const resource=resolveBindings(step.resource||{},context);
      const reason=resolveBindings(step.reason||"",context);
      const message=resolveBindings(step.message||"",context);
      const result=await capabilityRunner({capability:step.capability,resource,reason,message,step});
      const status=result?.status||((result?.ok||result?.result?.ok)?"executed":"error");
      const record={step_id:step.id,type:step.type,capability:step.capability,status,duration_ms:Date.now()-started,result:result?.result??result};
      results.push(record);
      context.steps[step.id]=record;

      if(status==="approval_required"){
        return {
          ok:false,
          status:"approval_required",
          run_id:runId,
          workflow:workflow.name,
          product:workflow.product,
          started_at:startedAt,
          stopped_at:new Date().toISOString(),
          approval:{step_id:step.id,message:result?.reason||reason||"Capability approval required"},
          results
        };
      }
      if(status!=="executed"&&status!=="succeeded"){
        return {
          ok:false,
          status:"failed",
          run_id:runId,
          workflow:workflow.name,
          product:workflow.product,
          started_at:startedAt,
          finished_at:new Date().toISOString(),
          failed_step:step.id,
          results
        };
      }
    }
  }

  return {
    ok:true,
    status:"succeeded",
    run_id:runId,
    workflow:workflow.name,
    product:workflow.product,
    started_at:startedAt,
    finished_at:new Date().toISOString(),
    results
  };
}
