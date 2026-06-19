'use strict';

const { chromium } = require('@playwright/test');

async function main() {
  let browser;

  try {
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    const response = await page.goto('https://example.com', {
      waitUntil: 'domcontentloaded',
      timeout: 30_000
    });

    const result = {
      ok: response?.ok() ?? false,
      status: response?.status() ?? null,
      title: await page.title(),
      url: page.url()
    };

    console.log(JSON.stringify(result, null, 2));

    if (!result.ok) {
      process.exitCode = 1;
    }
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      error: error instanceof Error ? error.message : String(error)
    }, null, 2));
    process.exitCode = 1;
  } finally {
    await browser?.close();
  }
}

main();
