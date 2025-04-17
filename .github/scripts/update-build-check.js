module.exports = async ({ github, context, buildTestOutcome, uploadOutcome, artifactUrl, checkName, headSha, runId }) => {
  const owner = context.repo.owner;
  const repo = context.repo.repo;
  const runUrl = `${process.env.GITHUB_SERVER_URL}/${owner}/${repo}/actions/runs/${runId}`;

  let conclusion;
  let summary;
  let title;
  let detailsUrl = runUrl; // Default details URL to the run page

  // --- Determine status based on outcomes ---
  if (buildTestOutcome == 'success' && uploadOutcome == 'success' && artifactUrl) {
    conclusion = 'success';
    title = 'Build Succeeded & Artifact Ready';
    summary = `✅ Simulator build completed successfully.\n\n` +
              `[Download Build Artifact (.app)](${artifactUrl}) (Login Required)\n\n` +
              `[View Full Workflow Run & Other Artifacts](${runUrl})`;
    // Optionally make the direct artifact link the main details_url for the check:
    // detailsUrl = artifactUrl;
  } else if (buildTestOutcome == 'success' && uploadOutcome != 'success') {
    conclusion = 'failure';
    title = 'Build Succeeded, Artifact Upload Failed';
    summary = `⚠️ The simulator build completed, but the artifact upload failed.\n\n` +
              `[View Workflow Run Details](${runUrl})`;
  } else if (buildTestOutcome == 'failure') {
    conclusion = 'failure';
    title = 'Build or Tests Failed';
    summary = `❌ The build or unit tests failed. No artifact was uploaded.\n\n` +
              `[View Workflow Run Details](${runUrl})`;
  } else if (buildTestOutcome == 'cancelled') {
    conclusion = 'cancelled';
    title = 'Build Cancelled';
    summary = `⏹️ The build was cancelled.\n\n[View Workflow Run Details](${runUrl})`;
  } else {
    conclusion = 'neutral';
    title = 'Build Status Unknown';
    summary = `❓ The build status could not be determined.\n\n[View Workflow Run Details](${runUrl})`;
  }

  // --- Make the API call using the passed 'github' instance ---
  console.log(`Updating check run '${checkName}' for SHA ${headSha} with conclusion ${conclusion}`);
  await github.rest.checks.create({
    owner: owner,
    repo: repo,
    name: checkName,
    head_sha: headSha,
    status: 'completed',
    conclusion: conclusion,
    completed_at: new Date().toISOString(),
    output: {
      title: title,
      summary: summary
    },
    details_url: detailsUrl
  });

  console.log('Check run update complete.');
};
