export type TemplateCategory = 'retention' | 'monetisation' | 'social' | 'onboarding';
export type TemplateImpact = 'low' | 'medium' | 'high';

export interface TemplateMetadata {
  id: string;
  name: string;
  summary: string;
  description: string;
  category: TemplateCategory;
  impact: TemplateImpact;
}

/**
 * Public catalogue metadata only. Executable workflow nodes, notification copy,
 * trigger matching, and delivery policy remain proprietary Notifie Cloud logic.
 */
export const NOTIFIE_TEMPLATE_CATALOG: TemplateMetadata[] = [
  {
    id: 'ask-for-review',
    name: 'Ask for Review',
    summary: 'Request a review after a user has clearly had a good experience.',
    description:
      'Asks for a review after a customer has had time to use what they purchased.',
    category: 'monetisation',
    impact: 'high',
  },
  {
    id: 'subscription-recovery',
    name: 'Subscription Recovery',
    summary: 'Win back users in the window after they cancel.',
    description:
      'Re-engages customers after cancellation without interrupting people who return by themselves.',
    category: 'monetisation',
    impact: 'high',
  },
  {
    id: 'welcome-back',
    name: 'Welcome Back',
    summary: 'Reach users who finish onboarding and then disappear.',
    description:
      'Encourages newly onboarded users to return when they have not continued on their own.',
    category: 'retention',
    impact: 'high',
  },
  {
    id: 'trial-ending',
    name: 'Trial Ending',
    summary: 'Remind trial users before they lose access.',
    description: 'Helps trial users make a decision before their access expires.',
    category: 'monetisation',
    impact: 'medium',
  },
  {
    id: 'generation-ready',
    name: 'AI Generation Ready',
    summary: 'Tell users the moment their long-running job finishes.',
    description: 'Brings users back when an asynchronous result is ready to view.',
    category: 'retention',
    impact: 'high',
  },
  {
    id: 'achievement-celebration',
    name: 'Achievement Celebration',
    summary: 'Acknowledge a milestone while it still feels good.',
    description: 'Recognizes meaningful progress and reinforces the behavior that produced it.',
    category: 'social',
    impact: 'medium',
  },
  {
    id: 'daily-reminder',
    name: 'Daily Reminder',
    summary: 'Bring habit users back the next day.',
    description: 'Supports products whose value grows through consistent daily use.',
    category: 'retention',
    impact: 'medium',
  },
];

export function findTemplateMetadata(id: string): TemplateMetadata | undefined {
  return NOTIFIE_TEMPLATE_CATALOG.find((template) => template.id === id);
}
