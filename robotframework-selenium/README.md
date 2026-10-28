# Robot Framework Selenium pipeline

Parameterized Jenkins pipeline for `robotframework_selenium`.

## Jenkins setup
1. Create a Jenkins Pipeline job.
2. Choose **Pipeline script from SCM** and Git.
3. Repository: `https://github.com/SanthoshJeeva440/automation-pipelines.git`
4. Branch: `*/main`
5. Script Path: `pipelines/robotframework-selenium/Jenkinsfile`
6. Save and select **Build with Parameters**.

Requires the **Pipeline Utility Steps** plugin (`readYaml`) and **Email Extension Plugin** (`emailext`). Configure SMTP under **Manage Jenkins → System → Extended E-mail Notification**.

Parameters: `AGENT`, `ENV`, `BROWSER`, `TAGS`, `HEADLESS`, and `EMAIL_TO`.

The pipeline reads `robotframework-selenium/config.yml` from `automation-ci-config` and checks out the test repository's `master` branch. It attempts to attach `report.html`, `log.html`, and `output.xml`, plus the console log.

Browser compatibility note: the existing project requirements and README indicate SeleniumLibrary-based tests. WebKit is not supported by SeleniumLibrary itself. Ensure the suite's imports and browser setup match the selected browser.
