export type NotifieFetch = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

export class NotifieClient {
  constructor(
    private readonly apiKey: string,
    private readonly baseUrl: string,
    private readonly anonymousId: string,
    private readonly request: NotifieFetch,
  ) {}

  async track(
    eventName: string,
    properties: Record<string, string | number | boolean | null> = {},
  ): Promise<void> {
    if (!eventName.trim()) throw new Error('Event name cannot be empty.');

    const response = await this.request(
      `${this.baseUrl.replace(/\/$/, '')}/api/v1/events`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: JSON.stringify({
          events: [{
            anonymousId: this.anonymousId,
            event: eventName,
            properties,
          }],
        }),
      },
    );

    if (!response.ok) {
      throw new Error(`Notifie request failed with status ${response.status}.`);
    }
  }
}