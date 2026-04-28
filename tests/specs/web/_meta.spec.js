const { test, expect } = require('@playwright/test')

test('@smoke rails health responds', async ({ request }) => {
  const res = await request.get('http://localhost:3001/api/health')
  expect(res.ok()).toBe(true)
})
