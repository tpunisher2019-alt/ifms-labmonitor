import { headers } from "next/headers";

export async function POST(request:Request){
  const h=await headers(); const operator=h.get("oai-authenticated-user-email");
  if(!operator&&process.env.NODE_ENV!=="development") return Response.json({error:"unauthorized"},{status:401});
  const url=process.env.SUPABASE_URL; const key=process.env.SUPABASE_SECRET_KEY;
  if(!url||!key) return Response.json({error:"not_configured"},{status:503});
  const body=await request.json(); const deviceIds=Array.isArray(body.deviceIds)?body.deviceIds:[];
  if(!deviceIds.length||!["inventory_refresh","agent_update"].includes(body.type)) return Response.json({error:"invalid_request"},{status:400});
  const auth={apikey:key,Authorization:`Bearer ${key}`,"content-type":"application/json",Prefer:"return=representation"};
  const jobRes=await fetch(`${url}/rest/v1/jobs`,{method:"POST",headers:auth,body:JSON.stringify({type:body.type,payload:body.releaseId?{releaseId:body.releaseId}:{},created_by:operator??"local-development"})});
  if(!jobRes.ok)return Response.json({error:"job_failed"},{status:502}); const [job]=await jobRes.json();
  const targets=deviceIds.map((device_id:string)=>({job_id:job.id,device_id}));
  const targetRes=await fetch(`${url}/rest/v1/device_jobs`,{method:"POST",headers:auth,body:JSON.stringify(targets)});
  if(!targetRes.ok)return Response.json({error:"targets_failed"},{status:502});
  return Response.json({ok:true,jobId:job.id});
}

