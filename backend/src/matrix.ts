export type Bindings = {
  API_TOKEN: string; MATRIX_ACCESS_TOKEN: string;
  BROWSER_USE_API_KEY?: string; BROWSER_USE_MODEL?: string;
  RESEARCH_JOBS?: DurableObjectNamespace;
  MATRIX_PLATFORM_URL: string; MATRIX_AUTH_URL: string;
  MATRIX_COMPUTER: string; MATRIX_RUNNER_PATH: string;
};
export class ApiError extends Error {
  constructor(public code: string, public status = 502) { super(code); }
}
export interface Executor { call(operation: string, ...args: string[]): Promise<any> }

export class Matrix implements Executor {
  constructor(private env: Bindings, private request: typeof fetch = fetch) {}
  private async json(url: string, token: string, init: RequestInit = {}) {
    let response: Response;
    try {
      response = await this.request.call(globalThis, url, { ...init, redirect: 'manual',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        signal: AbortSignal.timeout(20_000) });
    } catch (error) {
      console.warn('Matrix request failed', new URL(url).pathname,
        error instanceof Error ? error.message.replaceAll(token, '[redacted]') : 'network error');
      throw new ApiError('matrix_unreachable', 503);
    }
    if ([401, 403].includes(response.status)) throw new ApiError('matrix_auth_required', 503);
    if (!response.ok) throw new ApiError('matrix_request_failed', 502);
    try { return await response.json() as any; } catch { throw new ApiError('matrix_invalid_response'); }
  }
  async call(operation: string, ...args: string[]) {
    const env = this.env;
    if (!env.MATRIX_ACCESS_TOKEN || !env.MATRIX_RUNNER_PATH) throw new ApiError('matrix_not_configured', 503);
    const platform = new URL(env.MATRIX_PLATFORM_URL);
    const auth = new URL(env.MATRIX_AUTH_URL);
    if (platform.protocol !== 'https:' || auth.protocol !== 'https:') throw new ApiError('invalid_matrix_origin', 503);
    const inventory = await this.json(new URL('/api/auth/computers', platform).href, env.MATRIX_ACCESS_TOKEN);
    const computer = inventory.items?.find((item: any) => item.runtimeSlot === env.MATRIX_COMPUTER);
    if (!computer || computer.availability !== 'available') throw new ApiError('matrix_computer_unavailable', 503);
    const selected = await this.json(new URL('/api/auth/runtime-selection', auth).href, env.MATRIX_ACCESS_TOKEN,
      {method: 'POST', body: JSON.stringify({slot: env.MATRIX_COMPUTER})});
    if (selected.slot !== computer.runtimeSlot || selected.handle !== computer.handle ||
        typeof selected.accessToken !== 'string' || typeof selected.expiresAt !== 'number' || selected.expiresAt <= Date.now() ||
        !/^[a-z0-9][a-z0-9-]{1,62}$/.test(computer.handle)) throw new ApiError('matrix_invalid_runtime');
    const gateway = new URL(`/vm/${computer.handle}/api/terminal/run`, platform);
    if (computer.runtimeSlot !== 'primary') gateway.searchParams.set('runtime', computer.runtimeSlot);
    // Keep every terminal argument below Matrix's 4096-character limit.
    if (operation === 'submit') {
      const encoded = btoa(String.fromCharCode(...new TextEncoder().encode(args[0])));
      args = encoded.match(/.{1,3000}/g)!;
    }
    const result = await this.json(gateway.href, selected.accessToken, {method: 'POST', body: JSON.stringify({
      command: ['/usr/bin/python3', env.MATRIX_RUNNER_PATH, operation, ...args], timeoutMs: 10_000
    })});
    if (result.exitCode !== 0 || result.timedOut || result.truncated || typeof result.stdout !== 'string') {
      throw new ApiError('matrix_runner_failed');
    }
    let envelope;
    try { envelope = JSON.parse(result.stdout); } catch { throw new ApiError('matrix_runner_invalid_response'); }
    if (!envelope.ok) {
      const code = String(envelope.error);
      const status = code === 'idempotency_conflict' ? 409 :
        ['job_not_found', 'artifact_not_found'].includes(code) ? 404 :
        code === 'artifact_too_large' ? 413 : code.startsWith('invalid_') ? 400 : 502;
      throw new ApiError(code, status);
    }
    return envelope.data;
  }
}
