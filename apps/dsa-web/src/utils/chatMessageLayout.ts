export type ChatMessageRole = 'user' | 'assistant';

export type ChatMessageLayout = {
  expandedAssistant: boolean;
  showAvatar: boolean;
};

/** Mobile assistant output uses the full row; desktop and user messages keep avatars. */
export const getChatMessageLayout = (
  role: ChatMessageRole,
  isMobileApp: boolean,
): ChatMessageLayout => {
  const expandedAssistant = isMobileApp && role === 'assistant';
  return {
    expandedAssistant,
    showAvatar: !expandedAssistant,
  };
};
