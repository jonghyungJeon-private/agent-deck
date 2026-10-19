import React from 'react';
import {Composition} from 'remotion';
import {Intro, Teaser} from './video';

export const VideoRoot: React.FC = () => <>
  <Composition id="AgentDeckIntro" component={Intro} width={1920} height={1080} fps={30} durationInFrames={2760}/>
  <Composition id="AgentDeckTeaser" component={Teaser} width={1920} height={1080} fps={30} durationInFrames={420}/>
</>;
