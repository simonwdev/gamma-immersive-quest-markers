-- ======================================================================
--  IQM depth-RT spike -- script blender  (DEBUG SCAFFOLDING, not shipped)
-- ======================================================================
-- Proves three things before the route renderer is allowed to depend on any
-- of them. See docs/shader-spike.md for what each mode answers.
--
-- This is a COPY of the stock UI blender (shaders/r3/hud_default.s, which is
-- what every CUIStatic in the game draws through) with one line added: the
-- deferred position render target bound as a second texture. Everything else
-- -- the vertex shader, the blend mode, the depth state -- is deliberately
-- identical to stock, so that anything the spike shows differently is the
-- depth read and not a state change we made by accident.
--
-- The name matters twice over. On DX10/11 the engine resolves a shader name by
-- looking for gamedata/shaders/r3/<name>.s BEFORE it consults the C++ blender
-- library (ResourceManager.cpp:334), and the lookup is FS_RootOnly -- the file
-- has to sit directly in r3/, never a subfolder. Because the name is new rather
-- than an override of hud_default, no other shader mod in GAMMA is touched.

function normal (shader, t_base, t_second, t_detail)
	shader:begin ("stub_notransform_t", "iqm_depthspike")   -- vs, ps
			: blend (true, blend.srcalpha, blend.invsrcalpha)
			: zb    (false, false)
			: aref  (true, 0)

	shader:dx10texture ("s_base",     t_base)

	-- THE WHOLE POINT OF THE SPIKE. r2_RT_P, the deferred G-buffer position
	-- target (Layers/xrRenderPC_R3/r2_types.h:7). Its .z is view-space depth in
	-- metres. Whether it is still bound and holding THIS frame's scene when the
	-- UI pass runs is exactly the thing no amount of source reading settles.
	shader:dx10texture ("s_position", "$user$position")

	shader:dx10sampler ("smp_base"):clamp()
	shader:dx10sampler ("smp_nofilter")
end
