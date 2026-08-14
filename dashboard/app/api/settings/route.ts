import { headers } from "next/headers";

export async function POST(request:Request){
  const h=await headers(); const operator=h.get("oai-authenticated-user-email");
  if(!operator&&process.env.NODE_ENV!=="development") return Response.json({error:"unauthorized"},{status:401});
  const url=process.env.SUPABASE_URL; const key=process.env.SUPABASE_SECRET_KEY;
  if(!url||!key) return Response.json({error:"not_configured"},{status:503});
  const {retentionDays}=await request.json(); const days=Number(retentionDays);
  if(!Number.isInteger(days)||days<7||days>3650) return Response.json({error:"invalid_retention"},{status:400});
  const response=await fetch(`${url}/rest/v1/system_settings?id=eq.true`,{method:"PATCH",headers:{apikey:key,Authorization:`Bearer ${key}`,"content-type":"application/json"},body:JSON.stringify({event_retention_days:days,updated_at:new Date().toISOString(),updated_by:operator??"local-development"})});
  if(!response.ok)return Response.json({error:"update_failed"},{status:502});
  return Response.json({ok:true,retentionDays:days});
}

