import { headers } from "next/headers";

export async function POST(request:Request){
  const h=await headers(); const operator=h.get("oai-authenticated-user-email");
  if(!operator&&process.env.NODE_ENV!=="development") return Response.json({error:"unauthorized"},{status:401});
  const url=process.env.SUPABASE_URL; const key=process.env.SUPABASE_SECRET_KEY;
  if(!url||!key) return Response.json({error:"not_configured"},{status:503});
  const body=await request.json(); const deviceIds=Array.isArray(body.deviceIds)?body.deviceIds:[];
  if(!deviceIds.length||!["inventory_refresh","agent_update"].includes(body.type)) return Response.json({error:"invalid_request"},{status:400});
  const auth={apikey:key,Authorization:`Bearer ${key}`,"content-type":"application/json",Prefer:"return=representation"};
  if(body.type==="agent_update"){
    if(!body.releaseId)return Response.json({error:"release_required"},{status:400});
    const releaseRes=await fetch(`${url}/rest/v1/agent_releases?id=eq.${encodeURIComponent(body.releaseId)}&active=eq.true&select=id,platform`,{headers:auth,cache:"no-store"});
    const deviceFilter=deviceIds.map((id:string)=>encodeURIComponent(id)).join(",");
    const devicesRes=await fetch(`${url}/rest/v1/devices?id=in.(${deviceFilter})&select=id,os_type`,{headers:auth,cache:"no-store"});
    if(!releaseRes.ok||!devicesRes.ok)return Response.json({error:"compatibility_check_failed"},{status:502});
    const [release]=await releaseRes.json(); const devices=await devicesRes.json();
    const platform=(osType:string)=>String(osType||"").toLowerCase().startsWith("win")?"windows":"linux";
    if(!release||devices.length!==new Set(deviceIds).size||devices.some((device:{os_type:string})=>platform(device.os_type)!==release.platform)) return Response.json({error:"incompatible_device_platform"},{status:400});
  }
  const jobRes=await fetch(`${url}/rest/v1/jobs`,{method:"POST",headers:auth,body:JSON.stringify({type:body.type,payload:body.releaseId?{releaseId:body.releaseId}:{},created_by:operator??"local-development"})});
  if(!jobRes.ok)return Response.json({error:"job_failed"},{status:502}); const [job]=await jobRes.json();
  const targets=deviceIds.map((device_id:string)=>({job_id:job.id,device_id}));
  const targetRes=await fetch(`${url}/rest/v1/device_jobs`,{method:"POST",headers:auth,body:JSON.stringify(targets)});
  if(!targetRes.ok)return Response.json({error:"targets_failed"},{status:502});
  return Response.json({ok:true,jobId:job.id});
}

