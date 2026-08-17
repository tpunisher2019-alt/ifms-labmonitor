const cors={"access-control-allow-origin":"*","access-control-allow-headers":"authorization, x-client-info, apikey, content-type","access-control-allow-methods":"POST,OPTIONS","content-type":"application/json"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});

Deno.serve(async(request)=>{
  if(request.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(request.method!=="POST")return reply({error:"method_not_allowed"},405);
  const url=Deno.env.get("SUPABASE_URL")!;
  const secret=Deno.env.get("SUPABASE_SECRET_KEY")??Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authorization=request.headers.get("authorization")||"";
  const baseHeaders={apikey:secret,Authorization:`Bearer ${secret}`,"content-type":"application/json"};
  const userResponse=await fetch(`${url}/auth/v1/user`,{headers:{apikey:secret,Authorization:authorization}});
  if(!userResponse.ok)return reply({error:"unauthorized"},401);
  const caller=await userResponse.json();
  const profileResponse=await fetch(`${url}/rest/v1/profiles?id=eq.${encodeURIComponent(caller.id)}&select=id,role,active`,{headers:baseHeaders});
  const [profile]=await profileResponse.json();
  if(!profile?.active||profile.role!=="admin")return reply({error:"admin_required"},403);
  const body=await request.json().catch(()=>({}));
  const cleanupReleases=async()=>{
    const releasesResponse=await fetch(`${url}/rest/v1/agent_releases?select=id,version,storage_path&order=created_at.desc,id.desc`,{headers:baseHeaders});
    const releases=await releasesResponse.json().catch(()=>[]);
    if(!releasesResponse.ok)return {ok:false,error:"release_list_failed",removed:[]};
    const retained=releases.slice(0,2);
    if(retained.length){
      const retainedIds=retained.map((release:{id:string})=>release.id).join(",");
      const activateResponse=await fetch(`${url}/rest/v1/agent_releases?id=in.(${encodeURIComponent(retainedIds)})`,{method:"PATCH",headers:{...baseHeaders,Prefer:"return=minimal"},body:JSON.stringify({active:true})});
      if(!activateResponse.ok)return {ok:false,error:"release_activation_failed",removed:[]};
    }
    const obsolete=releases.slice(2);
    if(!obsolete.length)return {ok:true,removed:[]};
    const storageResponse=await fetch(`${url}/storage/v1/object/agent-releases`,{method:"DELETE",headers:baseHeaders,body:JSON.stringify({prefixes:obsolete.map((release:{storage_path:string})=>release.storage_path)})});
    if(!storageResponse.ok)return {ok:false,error:"storage_cleanup_failed",removed:[]};
    const ids=obsolete.map((release:{id:string})=>release.id).join(",");
    const databaseResponse=await fetch(`${url}/rest/v1/agent_releases?id=in.(${encodeURIComponent(ids)})`,{method:"DELETE",headers:{...baseHeaders,Prefer:"return=minimal"}});
    return {ok:databaseResponse.ok,error:databaseResponse.ok?null:"release_cleanup_failed",removed:databaseResponse.ok?obsolete.map((release:{version:string})=>release.version):[]};
  };
  if(body.action==="list"){
    const response=await fetch(`${url}/rest/v1/profiles?select=id,email,full_name,role,active,created_at&order=active.desc,role.asc,full_name.asc`,{headers:baseHeaders});
    return reply({users:await response.json()},response.ok?200:502);
  }
  if(body.action==="metrics"){
    const retention=await cleanupReleases();
    if(!retention.ok)return reply({error:retention.error},502);
    const response=await fetch(`${url}/rest/v1/rpc/get_admin_storage_metrics`,{method:"POST",headers:baseHeaders,body:"{}"});
    const metrics=await response.json().catch(()=>null);
    return reply({metrics,releaseRetention:retention},response.ok?200:502);
  }
  if(body.action==="create"){
    const email=String(body.email||"").trim().toLowerCase(),fullName=String(body.fullName||"").trim(),password=String(body.password||""),role=body.role==="admin"?"admin":body.role==="monitor"?"monitor":"";
    if(!/^[^\s@]+@ifms\.edu\.br$/i.test(email)||fullName.length<3||password.length<7||!role)return reply({error:"invalid_input"},400);
    const response=await fetch(`${url}/auth/v1/admin/users`,{method:"POST",headers:baseHeaders,body:JSON.stringify({email,password,email_confirm:true,user_metadata:{full_name:fullName}})});
    const user=await response.json(); if(!response.ok)return reply({error:"create_failed",detail:user?.msg||user?.message},400);
    const update=await fetch(`${url}/rest/v1/profiles?id=eq.${encodeURIComponent(user.id)}`,{method:"PATCH",headers:{...baseHeaders,Prefer:"return=minimal"},body:JSON.stringify({full_name:fullName,role,active:true,updated_at:new Date().toISOString()})});
    return reply({ok:update.ok,id:user.id},update.ok?201:502);
  }
  if(body.action==="update"){
    if(!body.userId||body.userId===caller.id)return reply({error:"protected_user"},400);
    const changes:{active?:boolean;role?:string;updated_at:string}={updated_at:new Date().toISOString()};
    if(typeof body.active==="boolean")changes.active=body.active;
    if(body.role==="admin"||body.role==="monitor")changes.role=body.role;
    const response=await fetch(`${url}/rest/v1/profiles?id=eq.${encodeURIComponent(body.userId)}`,{method:"PATCH",headers:{...baseHeaders,Prefer:"return=minimal"},body:JSON.stringify(changes)});
    if(changes.active===false)await fetch(`${url}/auth/v1/admin/users/${encodeURIComponent(body.userId)}`,{method:"PUT",headers:baseHeaders,body:JSON.stringify({ban_duration:"876000h"})});
    if(changes.active===true)await fetch(`${url}/auth/v1/admin/users/${encodeURIComponent(body.userId)}`,{method:"PUT",headers:baseHeaders,body:JSON.stringify({ban_duration:"none"})});
    return reply({ok:response.ok},response.ok?200:502);
  }
  if(body.action==="delete"){
    const userId=String(body.userId||"");
    if(!userId||userId===caller.id)return reply({error:"protected_user"},400);
    const targetResponse=await fetch(`${url}/rest/v1/profiles?id=eq.${encodeURIComponent(userId)}&select=id,email,role,active`,{headers:baseHeaders});
    const [target]=await targetResponse.json();
    if(!target)return reply({error:"user_not_found"},404);
    if(target.role==="admin"&&target.active){
      const adminsResponse=await fetch(`${url}/rest/v1/profiles?role=eq.admin&active=eq.true&select=id`,{headers:baseHeaders});
      const admins=await adminsResponse.json();
      if(!adminsResponse.ok||admins.length<=1)return reply({error:"last_admin"},400);
    }
    await fetch(`${url}/auth/v1/admin/users/${encodeURIComponent(userId)}`,{method:"PUT",headers:baseHeaders,body:JSON.stringify({ban_duration:"876000h"})});
    const response=await fetch(`${url}/auth/v1/admin/users/${encodeURIComponent(userId)}`,{method:"DELETE",headers:baseHeaders});
    const detail=response.ok?null:await response.json().catch(()=>null);
    return reply({ok:response.ok,detail},response.ok?200:502);
  }
  return reply({error:"unknown_action"},400);
});
