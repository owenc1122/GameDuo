// Compute the four fixed FXAA sampling coordinates once per vertex instead
// of once per output pixel; affine interpolation preserves the same footprint.
#ifdef GL_ES
precision mediump float;
precision mediump int;
#endif
attribute vec4 a_position;
attribute vec2 a_texcoord0;
uniform vec2 u_texelDelta;
varying vec2 v_texcoord0;
varying vec4 v_texcoord1;
varying vec4 v_texcoord2;
void main() {
  gl_Position = a_position;
  v_texcoord0 = a_texcoord0;
  v_texcoord1 = a_texcoord0.xyxy + vec4(-1.0, -1.0, 1.0, -1.0) * u_texelDelta.xyxy;
  v_texcoord2 = a_texcoord0.xyxy + vec4(-1.0, 1.0, 1.0, 1.0) * u_texelDelta.xyxy;
}
