const api = 'https://habitica.com/api/v3/';
const client = '5a8238ab-1819-4f7f-a750-f23264719a2d-HabiticaPomodoroSiteKeeper-Web';

async function request(connection, path, method = 'GET') {
  let response;
  try {
    response = await fetch(new URL(path, api), {
      method, credentials: 'omit', redirect: 'error', cache: 'no-store',
      signal: AbortSignal.timeout(15_000),
      headers: { 'x-client': client, 'x-api-user': connection.user, 'x-api-key': connection.token },
    });
  } catch {
    throw new Error('无法连接 Habitica，请检查网络后重试。');
  }
  if (response.status === 401) throw new Error('Habitica 凭据无效，请核对 User ID 和 API Token。');
  if (response.status === 429) throw new Error('Habitica 请求过于频繁，请稍后再试。');
  if (!response.ok) throw new Error(`Habitica 请求失败（HTTP ${response.status}）。`);
  const payload = await response.json().catch(() => null);
  if (!payload?.success || !payload.data) throw new Error('Habitica 返回了无法识别的结果。');
  return payload.data;
}

export async function loadAccount(connection) {
  const [user, tasks] = await Promise.all([
    request(connection, 'user?userFields=profile.name,stats'), request(connection, 'tasks/user'),
  ]);
  if (!user.stats || !Array.isArray(tasks)) throw new Error('Habitica 返回了无法识别的账号数据。');
  return { name: user.profile?.name || 'Habitica 角色', stats: user.stats, tasks };
}

export function scoreTask(connection, id, direction) {
  if (!/^[\w-]+$/.test(id) || !['up', 'down'].includes(direction)) {
    throw new Error('这个 Habitica 任务无法打分。');
  }
  return request(connection, `tasks/${encodeURIComponent(id)}/score/${direction}`, 'POST');
}
