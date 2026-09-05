async (page) => {
  const select = page.locator('select').first();
  const diagnostics = page.locator('input[type=checkbox]').nth(1);
  await select.selectOption('mobile');
  await diagnostics.check();
  await page.getByRole('button', {name: 'Save', exact: true}).click();
  await page.waitForTimeout(300);
  await page.reload();
  await page.locator('select').first().waitFor();
  const mobile = {client: await page.locator('select').first().inputValue(), diagnostics: await page.locator('input[type=checkbox]').nth(1).isChecked(), error: await page.locator('body').getAttribute('data-error')};
  if (mobile.client !== 'mobile' || mobile.diagnostics !== true || mobile.error) throw new Error('mobile/log1 reload assertion failed: ' + JSON.stringify(mobile));
  await page.locator('select').first().selectOption('pc');
  await page.locator('input[type=checkbox]').nth(1).uncheck();
  await page.getByRole('button', {name: 'Save', exact: true}).click();
  await page.waitForTimeout(300);
  await page.reload();
  await page.locator('select').first().waitFor();
  const pc = {client: await page.locator('select').first().inputValue(), diagnostics: await page.locator('input[type=checkbox]').nth(1).isChecked(), error: await page.locator('body').getAttribute('data-error')};
  if (pc.client !== 'pc' || pc.diagnostics !== false || pc.error) throw new Error('pc/log0 reload assertion failed: ' + JSON.stringify(pc));
  return {mobile, pc};
}
