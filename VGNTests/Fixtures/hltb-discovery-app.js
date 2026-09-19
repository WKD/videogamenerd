// Minimal excerpt mirroring howlongtobeat.com's real turbopack app chunk (2026-09-19).
// Two /api/ fetches: the GET /init token call (a template literal, no method) and the
// POST search call whose method:"POST" marks the real endpoint. The port must resolve
// the POST one → "search/site" and ignore the init GET.
(self.webpackChunk=self.webpackChunk||[]).push([[888],{12345:function(e,t,n){"use strict";
var er=async function(){try{let e=await fetch(`/api/search/site/init?t=${Date.now()}`);if(e.ok){let t=await e.json();return{token:t.token,hpKey:t.hpKey,hpVal:t.hpVal}}}catch(e){}return null};
var s=async function(o,t,a,r){let s=Object.assign({},o,{useCache:!0});a&&(s[a]=r);let n=await fetch("/api/search/site",{method:"POST",headers:{"Content-Type":"application/json","x-auth-token":t,"x-hp-key":a,"x-hp-val":r},body:JSON.stringify(s)});return n};
t.searchGames=s}}]);
