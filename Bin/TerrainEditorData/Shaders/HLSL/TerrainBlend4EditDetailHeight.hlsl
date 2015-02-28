#include "Uniforms.hlsl"
#include "Samplers.hlsl"
#include "Transform.hlsl"
#include "ScreenPos.hlsl"
#include "Lighting.hlsl"
#include "Fog.hlsl"

// When rendering a shadowed point light, disable specular calculations on Shader Model 2 to avoid exceeding the instruction limit
#if !defined(SM3) && defined(SHADOW) && defined(POINTLIGHT)
    #undef SPECULAR
#endif

sampler2D sWeightMap0 : register(S0);
sampler2D sDetailMap1 : register(S1);
sampler2D sDetailMap2 : register(S2);
sampler2D sDetailMap3 : register(S3);
sampler2D sDetailMap4 : register(S4);
sampler2D sMask : register(S12);

uniform float2 cDetailTiling;

float2 blendfactors(float4 texture1, float a1, float4 texture2, float a2)
{
	float depth = 0.2;
    float ma = max(texture1.a + a1, texture2.a + a2) - depth;

    float b1 = max(texture1.a + a1 - ma, 0);
    float b2 = max(texture2.a + a2 - ma, 0);
	return float2(b1,b2);
}

float4 blend(float4 texture1, float a1, float4 texture2, float a2)
{
    float2 b=blendfactors(texture1, a1, texture2, a2);

    return (texture1.rgba * b.x + texture2.rgba * b.y) / (b.x + b.y);
}

float4 sampleTerrain(sampler2D s, float2 uv)
{
	return (tex2D(s,uv)*0.65+tex2D(s,uv*0.435)*0.35);
}

float3 bump(sampler2D s, float2 uv)
{
	float3 n=float3(
		(sampleTerrain(s,float2(uv.x-0.002, uv.y)).a - sampleTerrain(s,float2(uv.x+0.002, uv.y)).a)/0.2,
		(sampleTerrain(s,float2(uv.x,uv.y-0.002)).a - sampleTerrain(s,float2(uv.x,uv.y+0.002)).a)/0.2,
		1
	);
	return normalize(n);
}

void VS(float4 iPos : POSITION,
    float3 iNormal : NORMAL,
    float2 iTexCoord : TEXCOORD0,
	#ifdef BUMPMAP
        float4 iTangent : TANGENT,
    #endif
    #ifndef BUMPMAP
        out float2 oTexCoord : TEXCOORD0,
    #else
        out float4 oTexCoord : TEXCOORD0,
        out float4 oTangent : TEXCOORD3,
    #endif
    out float3 oNormal : TEXCOORD1,
    out float4 oWorldPos : TEXCOORD2,
    out float2 oDetailTexCoord : TEXCOORD4,
    #ifdef PERPIXEL
        #ifdef SHADOW
            out float4 oShadowPos[NUMCASCADES] : TEXCOORD4,
        #endif
        #ifdef SPOTLIGHT
            out float4 oSpotPos : TEXCOORD5,
        #endif
        #ifdef POINTLIGHT
            out float3 oCubeMaskVec : TEXCOORD5,
        #endif
    #else
        out float3 oVertexLight : TEXCOORD4,
        out float4 oScreenPos : TEXCOORD5,
    #endif
    out float4 oPos : POSITION)
{
    float4x3 modelMatrix = iModelMatrix;
    float3 worldPos = GetWorldPos(modelMatrix);
    oPos = GetClipPos(worldPos);
    oNormal = GetWorldNormal(modelMatrix);
    oWorldPos = float4(worldPos, GetDepth(oPos));
    #ifdef BUMPMAP
        float3 tangent = GetWorldTangent(modelMatrix);
        float3 bitangent = cross(tangent, oNormal) * iTangent.w;
        oTexCoord = float4(GetTexCoord(iTexCoord), bitangent.xy);
        oTangent = float4(tangent, bitangent.z);
    #else
        oTexCoord = GetTexCoord(iTexCoord);
    #endif
    oDetailTexCoord = cDetailTiling * oTexCoord;

    #ifdef PERPIXEL
        // Per-pixel forward lighting
        float4 projWorldPos = float4(worldPos.xyz, 1.0);

        #ifdef SHADOW
            // Shadow projection: transform from world space to shadow space
            GetShadowPos(projWorldPos, oShadowPos);
        #endif

        #ifdef SPOTLIGHT
            // Spotlight projection: transform from world space to projector texture coordinates
            oSpotPos = mul(projWorldPos, cLightMatrices[0]);
        #endif

        #ifdef POINTLIGHT
            oCubeMaskVec = mul(worldPos - cLightPos.xyz, (float3x3)cLightMatrices[0]);
        #endif
    #else
        // Ambient & per-vertex lighting
        oVertexLight = GetAmbient(GetZonePos(worldPos));

        #ifdef NUMVERTEXLIGHTS
            for (int i = 0; i < NUMVERTEXLIGHTS; ++i)
                oVertexLight += GetVertexLight(i, worldPos, oNormal) * cVertexLights[i * 3].rgb;
        #endif
        
        oScreenPos = GetScreenPos(oPos);
    #endif
}

void PS(
	#ifndef BUMPMAP
        float2 iTexCoord : TEXCOORD0,
    #else
        float4 iTexCoord : TEXCOORD0,
        float4 iTangent : TEXCOORD3,
    #endif
    float3 iNormal : TEXCOORD1,
    float4 iWorldPos : TEXCOORD2,
    float2 iDetailTexCoord : TEXCOORD4,
    #ifdef PERPIXEL
        #ifdef SHADOW
            float4 iShadowPos[NUMCASCADES] : TEXCOORD4,
        #endif
        #ifdef SPOTLIGHT
            float4 iSpotPos : TEXCOORD5,
        #endif
        #ifdef CUBEMASK
            float3 iCubeMaskVec : TEXCOORD5,
        #endif
    #else
        float3 iVertexLight : TEXCOORD4,
        float4 iScreenPos : TEXCOORD5,
    #endif
    #ifdef PREPASS
        out float4 oDepth : COLOR1,
    #endif
    #ifdef DEFERRED
        out float4 oAlbedo : COLOR1,
        out float4 oNormal : COLOR2,
        out float4 oDepth : COLOR3,
    #endif
    out float4 oColor : COLOR0)
{
    // Get material diffuse albedo
	float4 weights=tex2D(sWeightMap0, iTexCoord.xy).rgba;
	float mask=tex2D(sMask, iTexCoord.xy).r;
    float sumWeights = weights.r + weights.g + weights.b + weights.a;
    weights /= sumWeights;
	
	float4 tex1=sampleTerrain(sDetailMap1, iDetailTexCoord);
	float4 tex2=sampleTerrain(sDetailMap2, iDetailTexCoord);
	float4 tex3=sampleTerrain(sDetailMap3, iDetailTexCoord);
	float4 tex4=sampleTerrain(sDetailMap4, iDetailTexCoord);
	
	float2 b1=blendfactors(tex1,weights.r,tex2,weights.g);
	float2 b2=blendfactors(tex3,weights.b,tex4,weights.a);
	
	float4 c1=(tex1*b1.x + tex2*b1.y) / (b1.x+b1.y);
	float a1=weights.r+weights.g;
	float4 c2=(tex3*b2.x + tex4*b2.y) / (b2.x+b2.y);
	float a2=weights.b+weights.a;
	
	float2 b3=blendfactors(c1,a1,c2,a2);
	float4 diffColor=cMatDiffColor * ((c1*b3.x + c2*b3.y)/(b3.x+b3.y));
	
	
    //float4 diffColor = cMatDiffColor * (
    //    weights.r * (tex2D(sDetailMap1, iDetailTexCoord) + tex2D(sDetailMap1, iDetailTexCoord*-0.345))*0.5 +
    //    weights.g * (tex2D(sDetailMap2, iDetailTexCoord)+tex2D(sDetailMap2, iDetailTexCoord*-0.345))*0.5 +
    //    weights.b * (tex2D(sDetailMap3, iDetailTexCoord)+tex2D(sDetailMap3, iDetailTexCoord*-0.345))*0.5 +
	//	weights.a * (tex2D(sDetailMap4, iDetailTexCoord)+tex2D(sDetailMap4, iDetailTexCoord*-0.345))*0.5
    //);
	diffColor=lerp(float4(1,0.5,0.3, diffColor.a), diffColor, mask);

    // Get material specular albedo
    float3 specColor = cMatSpecColor.rgb;
	
	// Get normal
    #ifdef BUMPMAP
        float3x3 tbn = float3x3(iTangent.xyz, float3(iTexCoord.zw, iTangent.w), iNormal);
        
		float3 bump1=bump(sDetailMap1, iDetailTexCoord);
		float3 bump2=bump(sDetailMap2, iDetailTexCoord);
		float3 bump3=bump(sDetailMap3, iDetailTexCoord);
		float3 bump4=bump(sDetailMap4, iDetailTexCoord);
		float3 nc1=(bump1*b1.x + bump2*b1.y) / (b1.x+b1.y);
		float3 nc2=(bump3*b2.x + bump4*b2.y) / (b2.x+b2.y);
		float3 normal=normalize(mul((nc1*b3.x+nc2*b3.y)/(b3.x+b3.y),tbn));
    #else
        float3 normal = normalize(iNormal);
    #endif

    // Get fog factor
    #ifdef HEIGHTFOG
        float fogFactor = GetHeightFogFactor(iWorldPos.w, iWorldPos.y);
    #else
        float fogFactor = GetFogFactor(iWorldPos.w);
    #endif

    #if defined(PERPIXEL)
        // Per-pixel forward lighting
        float3 lightDir;
        float3 lightColor;
        float3 finalColor;
        
        float diff = GetDiffuse(normal, iWorldPos.xyz, lightDir);

        #ifdef SHADOW
            diff *= GetShadow(iShadowPos, iWorldPos.w);
        #endif
    
        #if defined(SPOTLIGHT)
            lightColor = iSpotPos.w > 0.0 ? tex2Dproj(sLightSpotMap, iSpotPos).rgb * cLightColor.rgb : 0.0;
        #elif defined(CUBEMASK)
            lightColor = texCUBE(sLightCubeMap, iCubeMaskVec).rgb * cLightColor.rgb;
        #else
            lightColor = cLightColor.rgb;
        #endif
    
        #ifdef SPECULAR
            float spec = GetSpecular(normal, cCameraPosPS - iWorldPos.xyz, lightDir, cMatSpecColor.a);
            finalColor = diff * lightColor * (diffColor.rgb + spec * specColor * cLightColor.a);
        #else
            finalColor = diff * lightColor * diffColor.rgb;
        #endif

        #ifdef AMBIENT
            finalColor += cAmbientColor * diffColor.rgb;
            finalColor += cMatEmissiveColor;
            oColor = float4(GetFog(finalColor, fogFactor), diffColor.a);
        #else
            oColor = float4(GetLitFog(finalColor, fogFactor), diffColor.a);
        #endif
    #elif defined(PREPASS)
        // Fill light pre-pass G-Buffer
        float specPower = cMatSpecColor.a / 255.0;

        oColor = float4(normal * 0.5 + 0.5, specPower);
        oDepth = iWorldPos.w;
    #elif defined(DEFERRED)
        // Fill deferred G-buffer
        float specIntensity = specColor.g;
        float specPower = cMatSpecColor.a / 255.0;

        float3 finalColor = iVertexLight * diffColor.rgb;

        oColor = float4(GetFog(finalColor, fogFactor), 1.0);
        oAlbedo = fogFactor * float4(diffColor.rgb, specIntensity);
        oNormal = float4(normal * 0.5 + 0.5, specPower);
        oDepth = iWorldPos.w;
    #else
        // Ambient & per-vertex lighting
        float3 finalColor = iVertexLight * diffColor.rgb;

        #ifdef MATERIAL
            // Add light pre-pass accumulation result
            // Lights are accumulated at half intensity. Bring back to full intensity now
            float4 lightInput = 2.0 * tex2Dproj(sLightBuffer, iScreenPos);
            float3 lightSpecColor = lightInput.a * (lightInput.rgb / GetIntensity(lightInput.rgb));

            finalColor += lightInput.rgb * diffColor.rgb + lightSpecColor * specColor;
        #endif

        oColor = float4(GetFog(finalColor, fogFactor), diffColor.a);
    #endif
}
