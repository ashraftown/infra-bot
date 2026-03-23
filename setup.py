from setuptools import find_packages, setup


setup(
    name="infra-bot",
    version="0.1.0",
    description="Local Ubuntu update agent with Telegram alerts",
    python_requires=">=3.9",
    packages=find_packages(),
    install_requires=["PyYAML>=6.0"],
    entry_points={"console_scripts": ["infra-bot=infra_bot.cli:main"]},
)

