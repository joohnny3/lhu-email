'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require('@playwright/test');

const REQUIRED_ENV = ['LHU_URL', 'LHU_USERNAME', 'LHU_PASSWORD', 'MAIL_TO'];
const RESULT_FILE = path.resolve('state/lhu-weekly-email-result.json');
const RETRY_DELAY_MS = 15_000;

function taipeiDate() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Taipei',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  }).format(new Date());
}

function render(template, date) {
  return template.replaceAll('{{TODAY_TAIPEI}}', date);
}

function configFromEnv() {
  const missing = REQUIRED_ENV.filter((key) => !process.env[key]?.trim());
  if (missing.length > 0) throw new Error(`Missing required environment variables: ${missing.join(', ')}`);

  const url = new URL(process.env.LHU_URL);
  if (url.protocol !== 'https:') throw new Error('LHU_URL must use HTTPS');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(process.env.MAIL_TO)) throw new Error('MAIL_TO is not a valid email address');

  const date = taipeiDate();
  return {
    url: url.toString(),
    username: process.env.LHU_USERNAME,
    password: process.env.LHU_PASSWORD,
    recipient: process.env.MAIL_TO,
    subject: render(process.env.MAIL_SUBJECT_TEMPLATE || 'LHU weekly email {{TODAY_TAIPEI}}', date),
    body: render(process.env.MAIL_BODY_TEMPLATE || 'LHU weekly email {{TODAY_TAIPEI}}', date),
    date,
    send: process.env.LHU_SEND_EMAIL === 'true'
  };
}

function safeLocation(rawUrl) {
  const url = new URL(rawUrl);
  return `${url.origin}${url.pathname}`;
}

// The category tells the scheduler wrapper what to report: 'site-changed' needs a
// code fix, 'auth' needs new credentials.
function failure(category, message) {
  return Object.assign(new Error(message), { category });
}

async function saveFailureScreenshot(page) {
  const directory = path.resolve('artifacts/lhu-weekly-email');
  await fs.mkdir(directory, { recursive: true });
  const timestamp = new Date().toISOString().replaceAll(':', '-');
  const file = path.join(directory, `failure-${timestamp}.png`);
  await page.screenshot({ path: file, fullPage: true });
  return path.relative(process.cwd(), file);
}

async function saveResult(result) {
  // Read by scripts/run-lhu-weekly-email.ps1 to choose the failure notice. It is
  // advisory, so a write error must not turn a sent email into a failed run.
  try {
    await fs.mkdir(path.dirname(RESULT_FILE), { recursive: true });
    await fs.writeFile(RESULT_FILE, JSON.stringify(result, null, 2));
  } catch {
    // Keep the job's own outcome.
  }
}

async function login(page, config) {
  await page.goto(config.url, { waitUntil: 'domcontentloaded' });

  const username = page.locator('input[name="USERID"]:visible');
  // Mail2000 moved name="PASSWD" onto a hidden field that its own script fills on
  // submit; the visible box is now #passwd_plain. Match by type so both layouts work.
  const password = page.locator('input[type="password"]:visible');
  if (await username.count() !== 1 || await password.count() !== 1) {
    throw failure('site-changed', 'Could not identify the LHU login fields');
  }

  const form = password.locator('xpath=ancestor::form[1]');
  const action = new URL((await form.getAttribute('action')) || config.url, page.url());
  if (action.origin !== new URL(config.url).origin) {
    throw failure('site-changed', 'Refusing to submit credentials to a different origin');
  }

  const submit = form.locator('input[type="submit"]:visible, button[type="submit"]:visible');
  if (await submit.count() !== 1) throw failure('site-changed', 'Could not identify the LHU login button');

  await username.fill(config.username);
  await password.fill(config.password);
  await submit.click();
  // The page now submits from a promise callback, so the navigation starts after
  // click() returns. Wait for it rather than relying on a fixed sleep.
  await page.waitForURL((url) => safeLocation(url.href) !== safeLocation(config.url), { waitUntil: 'domcontentloaded' }).catch(() => undefined);
  await page.waitForTimeout(1_500);

  if (await page.locator('input[type="password"]:visible').count() > 0 || safeLocation(page.url()) === safeLocation(config.url)) {
    throw failure('auth', 'LHU login failed or could not be verified');
  }
}

async function openCompose(page) {
  await page.waitForTimeout(2_000);
  const submenu = page.frames().find((frame) => safeLocation(frame.url()).endsWith('/cgi-bin/submenu'));
  if (!submenu) throw failure('site-changed', 'Could not find the LHU submenu frame');

  const compose = submenu.locator('[onclick*="S_GoCompose"]');
  if (await compose.count() !== 1) throw failure('site-changed', 'Could not identify the LHU compose control');
  await compose.click();

  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const frame = page.frames().find((candidate) => safeLocation(candidate.url()).endsWith('/cgi-bin/genMail'));
    if (frame && await frame.locator('#SendButton').count() === 1) return frame;
    await page.waitForTimeout(250);
  }
  throw failure('site-changed', 'LHU compose form did not become ready');
}

async function fillAndVerify(compose, config) {
  const recipient = compose.locator('#ToText');
  const subject = compose.locator('#mailSubject');
  const body = compose.locator('#mailText');
  const send = compose.locator('#SendButton');

  if (await recipient.count() !== 1 || await subject.count() !== 1 || await body.count() !== 1 || await send.count() !== 1) {
    throw failure('site-changed', 'The LHU compose form structure has changed');
  }

  await recipient.fill(config.recipient);
  await recipient.press('Tab');
  await subject.fill(config.subject);
  await body.fill(config.body);

  const actual = {
    recipient: (await recipient.inputValue()).trim(),
    subject: await subject.inputValue(),
    body: await body.inputValue()
  };
  if (actual.recipient !== config.recipient || actual.subject !== config.subject || actual.body !== config.body) {
    throw failure('site-changed', 'Compose field verification failed');
  }

  return send;
}

async function attempt(config) {
  let browser;
  let page;
  let sendClicked = false;

  try {
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage();
    page.setDefaultTimeout(15_000);
    page.setDefaultNavigationTimeout(30_000);

    let unexpectedDialog = null;
    page.on('dialog', async (dialog) => {
      if (/寄|送|收件|mail|send/i.test(dialog.message())) {
        await dialog.accept();
      } else {
        unexpectedDialog = dialog.message();
        await dialog.dismiss();
      }
    });

    await login(page, config);
    const compose = await openCompose(page);
    const sendButton = await fillAndVerify(compose, config);

    if (!config.send) {
      return {
        ok: true,
        dryRun: true,
        recipient: config.recipient,
        subject: config.subject,
        body: config.body,
        date: config.date
      };
    }

    sendClicked = true;
    await sendButton.click();
    await page.waitForTimeout(4_000);
    if (unexpectedDialog) throw new Error(`Unexpected dialog while sending: ${unexpectedDialog}`);

    const sendButtonStillVisible = await compose.locator('#SendButton:visible').count() > 0;
    const successText = await compose.locator('body').innerText().catch(() => '');
    const successSignal = /寄信成功|郵件已送出|信件已寄出|sent successfully/i.test(successText);
    if (sendButtonStillVisible && !successSignal) {
      throw new Error('Email send could not be verified');
    }

    return {
      ok: true,
      sent: true,
      recipient: config.recipient,
      subject: config.subject,
      date: config.date
    };
  } catch (error) {
    let screenshot = null;
    if (page) {
      try {
        screenshot = await saveFailureScreenshot(page);
      } catch {
        // Preserve the original error.
      }
    }
    const message = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      category: sendClicked ? 'send-unverified' : (error?.category ?? (/net::ERR_/.test(message) ? 'network' : 'unknown')),
      error: message,
      screenshot
    };
  } finally {
    await browser?.close();
  }
}

async function main() {
  const config = configFromEnv();

  let result = await attempt(config);
  // A one-off timing glitch fails the same way a redesign does, so only report a
  // failure that repeats. Never retry once Send was clicked (duplicate mail) or
  // after a rejected login (repeated bad logins can lock the account).
  if (!result.ok && !['send-unverified', 'auth'].includes(result.category)) {
    console.error(JSON.stringify({ ...result, retrying: true }, null, 2));
    await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
    result = { ...await attempt(config), attempts: 2 };
  }

  await saveResult(result);
  if (result.ok) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.error(JSON.stringify(result, null, 2));
    process.exitCode = 1;
  }
}

main();
