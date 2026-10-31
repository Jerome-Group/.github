export const title = 'Independent profile snapshot refreshes';
const names = {idle:'Awaiting refresh',collecting:'Fetching and rendering',ready:'Complete output ready',failed:'Previous snapshot retained',published:'Complete snapshot published',broken:'Incomplete snapshot published'};
export const state = v => ({Personal:names[v.phase.personal], Organisation:names[v.phase.org]});
export const step = action => ({Start:'refresh starts',Render:'fetch and render succeed',Fail:'refresh fails',Publish:'push succeeds',BrokenPublish:'incomplete output is pushed',Done:'refreshes finished'})[action] ?? action;
